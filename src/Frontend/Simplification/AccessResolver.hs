module Frontend.Simplification.AccessResolver
(
    resolvePatternMatches
)
where

import Control.Monad.State
import CompilerUtilities.ProgramTable
import Frontend.AbstractSyntaxTree
import Data.Map.Strict (Map)
import Data.Maybe (fromMaybe, fromJust)
import qualified Data.Map.Strict as M
import Data.List.NonEmpty (NonEmpty(..))
import qualified Data.List.NonEmpty as NE
import Frontend.Simplification.Simplifier

type AccessResolver a = ProgramSimplifier ResolverState a

-- | Resolve pattern matches to corresponding member accesses.
resolvePatternMatches :: ProgramState -> ProgramState
resolvePatternMatches p = case runState program (initState p) of
    (p, ((_, t), _)) -> (p, t)

program :: AccessResolver Program
program = do
    (Program ps, _) <- gets fst
    Program <$> mapM pe ps

    where
    pe p@Proc {} = procedure p
    pe f@Func {} = function f
    pe a = pure a

procedure (Proc params retType name body) = Proc params retType name <$> mapM statement body

function (Func params retType name body) = Func params retType name <$> expression body

statement s = case s of
    Assignment v e -> Assignment v <$> expression e
    StmtExpr e -> StmtExpr <$> expression e

expression original@(Switch e cases def) = do
    let firstPattern = fst $ NE.head cases
    case firstPattern of
        Tuple es -> do
            markSequence e es
            let firstCase = snd $ NE.head cases
            expression firstCase

        App {} -> sumTypeCons
        Ident _ -> sumTypeCons
        _ -> pure original

    where
    sumTypeCons = do
        cases <- mapM _case cases
        pure $ Switch (Access e Tag) cases def

    _case (Ident a, expr) = do
        expr <- expression expr
        pure (Ident a, expr)

    _case (App (Ident cons) (Ident member), expr) = do
        markCons cons e member 0
        expr <- expression expr
        pure (Ident cons, expr)

    _case (App (Ident cons) (Tuple es), expr) = do
        markSequenceCons cons e es
        expr <- expression expr
        pure (Ident cons, expr)

expression (App l r) = do
    l <- expression l
    t <- getTable
    let (paramType `TArrow` _) = exprType t l
    case paramType of
        TProd ps ->
            case r of
                Ident _ -> pure $ App l $ g paramType r
                Tuple _ -> App l <$> expression r
        _ -> App l <$> expression r

    where
    g (TProd ts) (Ident s) = Tuple (NE.fromList $ h 0 (NE.toList ts))
        where
        h n [] = []
        h n (t:ts) = Access (Ident s) (Member n) : h (n + 1) ts

expression (Conditional c e1 e2) = do
    c <- expression c
    e1 <- expression e1
    Conditional c e1 <$> expression e2

expression (Tuple es) = Tuple <$> mapM expression es

expression (Lambda (ProcLambda name param body)) = do
    body <- mapM statement body
    pure $ Lambda $ ProcLambda name param body

expression (Lambda (FuncLambda name param body)) = do
    body <- expression body
    pure $ Lambda $ FuncLambda name param body

expression e@(Ident s) = fromMaybe e <$> lookupAccess s
expression e = pure e

-- | Mark identifiers in ascending order of memory access to be replaced by access expressions.
markSequence :: Expression -> NonEmpty Expression -> AccessResolver ()
markSequence container es = f 0 $ NE.toList es
    where
    f n [] = pure ()
    f n (Ident s:xs) = mark container s n >> f (n + 1) xs

-- | Mark identifiers in ascending order of memory access to be replaced by access expressions.
markSequenceCons :: Symbol -> Expression -> NonEmpty Expression -> AccessResolver ()
markSequenceCons cons container es = f 0 $ NE.toList es
    where
    f n [] = pure ()
    f n (Ident s:xs) = markCons cons container s n >> f (n + 1) xs

mark :: Expression -> Symbol -> Int -> AccessResolver ()
mark container s memberNo = do
    mapping <- getLocal
    let newMapping = M.insert s (Access container (Member memberNo)) mapping
    putLocal newMapping

markCons :: Symbol -> Expression -> Symbol -> Int -> AccessResolver ()
markCons cons container s memberNo = do
    ((p, (nextId, table)), mapping) <- get
    let (EntryValCons _ _ _ (Just (consIndex, _, _))) = fromJust $ M.lookup (symId cons) table
    let newMapping = M.insert s (Access container (ConsMember consIndex memberNo)) mapping
    put ((p, (nextId, table)), newMapping)

lookupAccess :: Symbol -> AccessResolver (Maybe Expression)
lookupAccess s = M.lookup s <$> gets snd

type ResolverState = Map Symbol Expression

initState :: ProgramState -> ProgramSimplifierState ResolverState
initState = initializeState M.empty