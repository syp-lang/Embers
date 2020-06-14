{-
Copyright (C) 2019  Syed Moiz Ur Rehman

This file is part of Embers.

Embers is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
any later version.

Embers is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with Embers.  If not, see <https://www.gnu.org/licenses/>.
-}

module Frontend.TypeSystem.TypeChecker
(
    typeCheck
)
where

import Control.Monad.Except
import Data.List.NonEmpty (NonEmpty((:|)), fromList, toList)
import qualified Data.List.NonEmpty as NE
import Control.Monad (unless)
import Control.Monad.State
import Data.Maybe (fromJust)
import Frontend.Error.TypeError
import Frontend.AbstractSyntaxTree
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import CompilerUtilities.ProgramTable
import Frontend.TypeSystem.Inference.ConstraintGenerator
import Frontend.TypeSystem.Inference.Unifier

type TypeChecker a = ExceptT TypeError (State TypeCheckerState) a

typeCheck :: ProgramState -> Either [TypeError] ProgramState
typeCheck (p, t) = case runState (runExceptT program) $! initState p t of
    (Right p, (_, t, [])) -> Right (p, t)
    (Right p, (_, t, err)) -> Left err
    (Left a, _) -> Left [a]

program = do
    (Program p, _, _) <- get
    Program <$> mapM programElement p

programElement elem = case elem of
        Ty _ -> pure elem
        Proc {} -> procedure elem
        Func {} -> function elem
        -- ExpressionVar {} -> tExpr elem -- TODO

procedure (Proc ps retType name stmts) = do
    mapM_ statementType $ NE.init stmts

    last <- statementType (NE.last stmts)
    stmts <- case last of
        Nothing -> do   -- Last statement is an assignment
            isUnitRetType <- isUnit retType
            if isUnitRetType
            then do
                u <- unitStmt
                pure $ fromList $ toList stmts ++ [u]
            else do
                addError $ NonUnitAssignment retType
                pure stmts
        Just typeExpr -> do
            assertWithError (ReturnTypeMismatch retType typeExpr) typeExpr retType
            pure stmts
    pure $ Proc ps retType name stmts

    where
    unitStmt = do
        t <- getTable
        let unit = unitId t
        pure $ StmtExpr $ Ident unit

    isUnit te = assertNominal te . unitId <$> getTable

function (Func ps retType name e) = do
    t <- expressionType e
    a <- assertStructural t retType
    unless a $ error $ "Return type in signature is " ++ show retType ++ ", but expression has type " ++ show t
    pure $ Func ps retType name e

statementType (Assignment var r) = do
    varType <- lookupType' (symId var)
    t <- expressionType r
    case varType of
        Nothing -> defineVarType var t
        Just someType -> do
            a <- assertStructural someType t
            unless a $ error $ show var ++ " has type " ++ show someType ++ " but a value of " ++ show t ++ " is assigned."
    pure Nothing  -- Assignment statement has no type.

statementType (StmtExpr e) = Just <$> expressionType e

expressionType (Lit l) = case l of
    NUMBER _ -> f intId
    CHAR _ -> f charId
    STRING _ -> error "String literal found."

    where f x = TCons . x <$> getTable

expressionType (Ident (Symb (ResolvedName id _) _)) = fromJust <$> lookupType' id

expressionType (Tuple es) = TProd <$> mapM expressionType es

expressionType e@(Lambda _) = inferType e >> fromJust <$> lookupType' (symId $ name e)
    where
    name (Lambda (FuncLambda n _ _)) = n
    name (Lambda (ProcLambda n _ _)) = n

expressionType (Conditional condition e1 e2) = do
    cType <- expressionType condition
    t <- getTable
    let b = boolId t
    unless (assertNominal cType b) $ addError $ ConditionalNonBool condition cType
    t1 <- expressionType e1
    t2 <- expressionType e2
    assertWithError (MismatchingBranches t1 t2) t1 t2
    pure t1

expressionType (Switch e cases def) = do
    exprType <- expressionType e
    let (patterns, caseExprs) = NE.unzip cases
    mapM_ (_pattern exprType) patterns
    let first = NE.head caseExprs
    firstType <- expressionType first
    mapM_ (_case firstType) caseExprs
    defType <- expressionType def
    assertWithError (MismatchingDefault firstType defType) firstType defType
    pure firstType

    where
    _pattern exprType p = do
        assignType p
        pType <- expressionType p
        assertWithError (SwitchPatternMismatch exprType pType) exprType pType

        where
        assignType p = case p of
            Lit _ -> pure ()
            Ident _ -> pure ()      -- Single identifier is a nullary value constructor.
            Tuple es -> assignProd es exprType
            App cons args -> do
                consType <- expressionType cons
                let (argType `TArrow` _) = consType
                case args of
                    Ident s -> defineVarType s argType
                    Tuple es -> assignProd es argType

            where
            assignProd es eType = case eType of
                TProd tExpr -> if NE.length tExpr == NE.length es
                    then mapM_ defineIdentType (NE.zip es tExpr)
                    else throwError $ TupleElementMismatch es exprType
                    -- else error $ "Cannot bind tuple elements " ++ show es ++ " to type " ++ show exprType
                -- _ -> error "Tuple pattern found on non-product type."
                t -> throwError $ TuplePatternNonProdType t

                where defineIdentType (Ident s, t) = defineVarType s t

    _case targetType caseExpr = do
        caseType <- expressionType caseExpr
        assertWithError (MismatchingCaseTypes targetType caseType) targetType caseType

expressionType (App l r) = do
    tl <- expressionType l
    unless (isArrow tl) $ throwError $ NonArrowApplication l tl
    let (TArrow paramType retType) = tl
    tr <- expressionType r
    if isPolymorphic tl
    then polymorphicApp l r tl tr
    else do
        assertWithError (ArgumentMismatch paramType tr) tr paramType
        pure retType

    where
    isArrow TArrow {} = True
    isArrow _ = False

    isPolymorphic te = case te of
        TVar _ -> True
        TCons _ -> False
        TArrow l r -> isPolymorphic l || isPolymorphic r
        TProd ts -> foldr (\a b -> isPolymorphic a || b) False ts

polymorphicApp l r tl tr = error "Polymorphic application not supported."

inferType :: Expression -> TypeChecker ()
inferType e = do
    (nextId, table) <- getTableState
    context <- toContext
    let (nextId', context', constraints) = generateConstraints e nextId context -- TODO: Merge contraint generation with Type Checker.
    let solution = unify (context', constraints)
    case solution of
        Right context -> do
            mapM_ updateTable (M.toList context)
            setNextId nextId'
        Left err -> throwError err

    where
    toContext :: TypeChecker (Map Symbol TypeExpression)
    toContext = do
        table <- getTable
        let filtered = M.filter pred table
        let symbols = map (idToName table) (M.keys filtered)
        types <- mapM toType symbols
        pure $ M.fromList (zip symbols types)

        where
        toType symbol = do
            table <- getTable
            case fromJust $ M.lookup (symId symbol) table of
                EntryTCons {} -> pure $ TCons symbol       -- Add primitive types so the inferrer can refer to them since they do not have value constructors.
                _ -> fromJust <$> lookupType' (symId symbol)

        pred entry = case entry of
            EntryTCons {} -> True
            EntryVar _ _ _ Nothing -> False
            EntryLambda _ _ _ _ Nothing -> False
            EntryTVar {} -> False
            _ -> True

    setNextId :: ID -> TypeChecker ()
    setNextId nextId = get >>= \(program, (_, table), err) -> put (program, (nextId, table), err)

    updateTable (symbol, tExpr) = do
        table <- getTable
        let entry = fromJust $ M.lookup (symId symbol) table
        case entry of   -- TODO: Add all (relevant?) polymorphic type variables to Table.
            EntryVar name absName scope Nothing -> setTable $ M.insert (symId symbol) (EntryVar name absName scope $ Just tExpr) table
            EntryLambda name absName scope paramIds Nothing -> setTable $ M.insert (symId symbol) (EntryLambda name absName scope paramIds $ Just $ arrowRight tExpr) table
            _ -> pure ()
        where
        arrowRight (_ `TArrow` r) = r

        setTable :: Table -> TypeChecker ()
        setTable table = do
            (program, (nextId, _), err) <- get
            put (program, (nextId, table), err)

assertWithError err t1 t2 = do
    a <- assertStructural t1 t2
    unless a $ addError err

assertStructural (TArrow l1 r1) (TArrow l2 r2) = do
    b1 <- assertStructural l1 l2
    b2 <- assertStructural r1 r2
    pure $ b1 && b2

assertStructural (TProd (x:|[])) (TProd (y:|[])) = assertStructural x y
assertStructural (TProd (_:|_)) (TProd (_:|[])) = pure False
assertStructural (TProd (x:|xs)) (TProd (y:|ys)) = do
    r1 <- assertStructural x y
    r2 <- assertStructural (TProd $ fromList xs) (TProd $ fromList ys)
    pure $ r1 && r2

assertStructural (TCons l) (TCons r) = pure $ l `cmpSymb` r
assertStructural (TVar l) (TVar r) = pure $ l `cmpSymb` r
assertStructural _ _ = pure False

assertNominal (TProd (TCons source:|[])) target = source `cmpSymb` target
assertNominal (TCons source) target = source `cmpSymb` target

type TypeCheckerState = (Program, TableState, [TypeError])

initState :: Program -> TableState -> TypeCheckerState
initState p t = (p, t, [])

-- | Define a symbol's type.
defineVarType (Symb (ResolvedName id absName) m) varType = do
    t <- getTable
    case lookupTableEntry id t of
        Just (EntryVar name absName scope Nothing) -> updateEntry id $ EntryVar name absName scope (Just varType)
        Just (EntryVar name absName scope (Just t)) -> if varType == t then pure () else error "Type conflict found."
--      Nested switch expressions call this ^ on variables with defined types. TODO: Investigate.

updateEntry :: ID -> TableEntry -> TypeChecker ()
updateEntry id newEntry = do
    (inp, (nextId, table), err) <- get
    table <- maybe (error "[Char]") pure (updateTableEntry id newEntry table)
    put (inp, (nextId, table), err)

lookupType' :: ID -> TypeChecker (Maybe TypeExpression)
lookupType' id = lookupType id <$> getTable

getTable :: TypeChecker Table
getTable = get >>= \(_, (_, table), _) -> pure table

getTableState = get >>= \(_, (id, table), _) -> pure (id, table)

addError :: TypeError -> TypeChecker ()
addError e = do
    (a, b, c) <- get
    put (a, b, e:c)
