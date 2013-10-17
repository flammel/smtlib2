{-# LANGUAGE RankNTypes,TypeFamilies,OverloadedStrings,GADTs,FlexibleContexts,ScopedTypeVariables,CPP,IncoherentInstances #-}
module Language.SMTLib2.Internals.Translation where

import Language.SMTLib2.Internals
import Language.SMTLib2.Internals.Instances
import Language.SMTLib2.Functions

import qualified Data.AttoLisp as L
import qualified Data.Attoparsec.Number as L
import Data.Typeable
import Data.Text as T (Text)
import Data.Array
import qualified Data.Map as Map (Map,lookup,elems)
import Data.Monoid
import Data.Unit
import Control.Monad.Trans

#ifdef SMTLIB2_WITH_CONSTRAINTS
import Data.Constraint
import Data.Proxy
#endif

instance L.ToLisp (SMTExpr t) where
  toLisp e = fst $ exprToLisp e 0

instance Show (SMTExpr t) where
  show x = show $ fst (exprToLisp x 0)

instance Show UntypedExpr where
  show (UntypedExpr x) = show x

-- | After a successful 'checkSat' call, extract values from the generated model.
--   The 'ProduceModels' option must be enabled for this.
getValue :: (SMTValue t,MonadIO m) => SMTExpr t -> SMT' m t
getValue expr = do
  let ann = extractAnnotation expr
  getValue' ann expr

-- | Extract values of compound expressions from the generated model.
getValue' :: (SMTValue t,MonadIO m) => SMTAnnotation t -> SMTExpr t -> SMT' m t
getValue' ann expr = do
  res <- getRawValue expr >>= return . removeLets
  case unmangle res ann of
    Nothing -> error $ "Couldn't unmangle "++show res
    Just r -> return r

getRawValue :: (SMTType t,MonadIO m) => SMTExpr t -> SMT' m L.Lisp
getRawValue expr = do
  clearInput
  putRequest $ L.List [L.Symbol "get-value"
                      ,L.List [L.toLisp expr]]
  val <- parseResponse
  case val of
    L.List [L.List [_,res]] -> return res
    _ -> error $ "unknown response to get-value: "++show val

-- | Define a new function with a body
defFun :: (Liftable a,SMTType r,Unit (ArgAnnotation a),Unit (SMTAnnotation r),MonadIO m) => (a -> SMTExpr r) -> SMT' m (SMTFun a r)
defFun = defFunAnn unit unit

-- | Define a new constant.
defConst :: (SMTType r,MonadIO m) => SMTExpr r -> SMT' m (SMTExpr r)
defConst = defConstNamed "constvar"

-- | Define a new constant with a name
defConstNamed :: (SMTType r,MonadIO m) => String -> SMTExpr r -> SMT' m (SMTExpr r)
defConstNamed name e = do
  fname <- freeName name
  let (expr',_) = exprToLisp e 0
      ann = extractAnnotation e
  defineFun fname [] (getSort (getUndef e) ann) expr'
  return $ Var fname ann

-- | Define a new function with a body and custom type annotations for arguments and result.
defFunAnnNamed :: (Liftable a,SMTType r,MonadIO m) => String -> ArgAnnotation a -> SMTAnnotation r -> (a -> SMTExpr r) -> SMT' m (SMTFun a r)
defFunAnnNamed name ann_arg ann_res f = do
  fname <- freeName name
  (names,_,_) <- getSMT
  let c_args = case Map.lookup "arg" names of
        Nothing -> 0
        Just n -> n

      res = SMTFun fname ann_res

      (_,rtp) = getFunUndef res

      (au,tps,c_args') = createArgs ann_arg (c_args+1)

      (expr',_) = exprToLisp (f au) c_args'
  defineFun fname tps (getSort rtp ann_res) expr'
  return res

-- | Like `defFunAnnNamed`, but defaults the function name to "fun".
defFunAnn :: (Liftable a,SMTType r,MonadIO m) => ArgAnnotation a -> SMTAnnotation r -> (a -> SMTExpr r) -> SMT' m (SMTFun a r)
defFunAnn = defFunAnnNamed "fun"

-- | Extract all values of an array by giving the range of indices.
unmangleArray :: (Liftable i,LiftArgs i,Ix (Unpacked i),SMTValue v,
                  --Unit (SMTAnnotation (Unpacked i)),
                  Unit (ArgAnnotation i),MonadIO m)
                 => (Unpacked i,Unpacked i)
                 -> SMTExpr (SMTArray i v)
                 -> SMT' m (Array (Unpacked i) v)
unmangleArray b expr = mapM (\i -> do
                                v <- getValue (App Select (expr,liftArgs i unit))
                                return (i,v)
                            ) (range b) >>= return.array b

exprsToLisp :: [SMTExpr t] -> Integer -> ([L.Lisp],Integer)
exprsToLisp [] c = ([],c)
exprsToLisp (e:es) c = let (e',c') = exprToLisp e c
                           (es',c'') = exprsToLisp es c'
                       in (e':es',c'')

exprToLisp :: SMTExpr t -> Integer -> (L.Lisp,Integer)
exprToLisp (Var name _) c = (L.Symbol name,c)
exprToLisp (Const x ann) c = (mangle x ann,c)
exprToLisp (AsArray f arg) c
  = let f' = getFunctionSymbol f arg
        (sargs,sres) = functionGetSignature f arg (inferResAnnotation f arg)
    in (L.List [L.Symbol "_",L.Symbol "as-array",if isOverloaded f
                                                 then L.List [f',L.List sargs,sres]
                                                 else f'],c)
exprToLisp (Forall ann f) c = let (arg,tps,nc) = createArgs ann c
                                  (arg',nc') = exprToLisp (f arg) nc
                              in (L.List [L.Symbol "forall"
                                         ,L.List [L.List [L.Symbol name,tp]
                                                  | (name,tp) <- tps]
                                         ,arg'],nc')
exprToLisp (Exists ann f) c = let (arg,tps,nc) = createArgs ann c
                                  (arg',nc') = exprToLisp (f arg) nc
                              in (L.List [L.Symbol "exists"
                                         ,L.List [L.List [L.Symbol name,tp]
                                                  | (name,tp) <- tps ]
                                         ,arg'],nc')
exprToLisp (Let ann x f) c = let (arg,tps,nc) = createArgs ann c
                                 (arg',nc') = unpackArgs (\e _ cc -> exprToLisp e cc
                                                         ) x ann nc
                                 (arg'',nc'') = exprToLisp (f arg) nc'
                             in (L.List [L.Symbol "let"
                                        ,L.List [L.List [L.Symbol name,lisp] | ((name,_),lisp) <- Prelude.zip tps arg' ]
                                        ,arg''],nc'')
exprToLisp (App fun x) c
  = case optimizeCall fun x of
    Nothing -> let arg_ann = extractArgAnnotation x
                   l = getFunctionSymbol fun arg_ann
                   ~(x',c1) = unpackArgs (\e _ i -> exprToLisp e i) x
                              arg_ann c
               in if Prelude.null x'
                  then (l,c1)
                  else (L.List $ l:x',c1)
    Just res -> exprToLisp res c
exprToLisp (Named expr name) c = let (expr',c') = exprToLisp expr c
                                 in (L.List [L.Symbol "!",expr',L.Symbol ":named",L.Symbol name],c')

unmangleDeclared :: ((forall a. (SMTValue a,Typeable a) => SMTExpr a -> b)) -> DeclaredType -> L.Lisp -> Maybe b
unmangleDeclared f d l
  = case withDeclaredValueType
         (\u ann -> case unmangle' u l ann of
             Nothing -> Nothing
             Just r -> Just $ f (Const r ann)) d of
      Just (Just x) -> Just x
      _ -> Nothing
  where
    unmangle' :: SMTValue a => a -> L.Lisp -> SMTAnnotation a -> Maybe a
    unmangle' _ = unmangle

createVarDeclared :: ((forall a. SMTType a => SMTExpr a -> b)) -> DeclaredType -> Text -> b
createVarDeclared f d name
  = withDeclaredType (\u ann -> f (eq u (Var name ann))) d
  where
    eq :: a -> SMTExpr a -> SMTExpr a
    eq = const id

newtype FunctionParser = FunctionParser { parseFun :: L.Lisp
                                                      -> FunctionParser
                                                      -> SortParser
                                                      -> Maybe FunctionParser' }

instance Monoid FunctionParser where
  mempty = FunctionParser $ \_ _ _ -> Nothing
  mappend p1 p2 = FunctionParser $ \l fun sort -> case parseFun p1 l fun sort of
    Nothing -> parseFun p2 l fun sort
    Just r -> Just r

data FunctionParser'
  = OverloadedParser { deriveRetSort :: [Sort] -> Maybe Sort
                     , parseOverloaded :: forall a. [Sort] -> Sort
                                          -> (forall f. SMTFunction f => f -> a)
                                          -> Maybe a }
  | DefinedParser { definedArgSig :: [Sort]
                  , definedRetSig :: Sort
                  , parseDefined :: forall a. (forall f. SMTFunction f => f -> a)
                                     -> Maybe a }

lispToExpr :: FunctionParser -> SortParser
              -> (T.Text -> Maybe UntypedExpr)
              -> Map.Map TyCon DeclaredType
              -> (forall a. SMTType a => SMTExpr a -> b) -> Maybe Sort -> L.Lisp -> Maybe b
lispToExpr fun sort bound tps f expected l
  = firstJust $
    [ unmangleDeclared f tp l | tp <- Map.elems tps ] ++
    [case l of
        L.Symbol name -> case bound name of
          Nothing -> Nothing
          Just subst -> entype (\subst' -> Just $ f subst') subst
        L.List [L.Symbol "forall",L.List args',body]
          -> fmap f $ quantToExpr Forall fun sort bound tps args' body
        L.List [L.Symbol "exists",L.List args',body]
          -> fmap f $ quantToExpr Exists fun sort bound tps args' body
        L.List [L.Symbol "let",L.List args',body]
          -> let struct = parseLetStruct fun sort bound tps expected args' body
             in Just $ convertLetStruct f struct
        L.List [L.Symbol "_",L.Symbol "as-array",fsym]
          -> case parseFun fun fsym fun sort of
          Nothing -> Nothing
          Just (DefinedParser arg_sort _ parse)
            -> parse $ \(rfun :: g) -> case getArgAnnotation (undefined::SMTFunArg g) arg_sort of
            (ann,[]) -> f (AsArray rfun ann)
            (_,_) -> error "smtlib2: Arguments not wholy parsed."
          Just _ -> error "smtlib2: as-array can't handle overloaded functions."
        L.List (fsym:args') -> case parseFun fun fsym fun sort of
          Nothing -> Nothing
          Just (OverloadedParser derive parse)
            -> do
            nargs <- lispToExprs args'
            let arg_tps = fmap (entype $ \(expr::SMTExpr t)
                                         -> toSort (undefined::t) (extractAnnotation expr)
                               ) nargs
            parse arg_tps
              (case derive arg_tps of
                  Nothing -> case expected of
                    Nothing -> error $ "smtlib2: Couldn't infer return type of "++show l
                    Just s -> s
                  Just s -> s) $
              \rfun -> case (do
                                (rargs,rest) <- toArgs nargs
                                case rest of
                                  [] -> Just $ App rfun rargs
                                  _ -> Nothing) of
                         Just e -> f e
                         Nothing -> error $ "smtlib2: Wrong arguments for function "++show fsym++": "++show nargs++" (expected: "++show arg_tps++")"
          Just (DefinedParser arg_tps _ parse) -> do
            nargs <- mapM (\(el,tp) -> lispToExpr fun sort bound tps UntypedExpr (Just tp) el)
                     (zip args' arg_tps)
            parse $ \rfun -> case (do
                                      (rargs,rest) <- toArgs nargs
                                      case rest of
                                        [] -> Just $ App rfun rargs
                                        _ -> Nothing) of
                               Just e -> f e
                               Nothing -> error $ "smtlib2: Wrong arguments for function "++show fsym++": "++show nargs
        _ -> Nothing
    ]
  where
    lispToExprs = mapM $ \arg -> lispToExpr fun sort bound tps (UntypedExpr) Nothing arg

quantToExpr :: (forall a. Args a => ArgAnnotation a -> (a -> SMTExpr Bool) -> SMTExpr Bool)
               -> FunctionParser -> SortParser
               -> (T.Text -> Maybe UntypedExpr)
               -> Map.Map TyCon DeclaredType -> [L.Lisp] -> L.Lisp -> Maybe (SMTExpr Bool)
quantToExpr q fun sort bound tps' (L.List [L.Symbol var,tp]:rest) body
  = let decl = declForSMTType tp tps'
        getForall :: Typeable a => a -> SMTExpr a -> SMTExpr a
        getForall = const id
    in Just $ withDeclaredType
       (\u ann ->
         q ann $ \subst -> case quantToExpr q fun sort
                                (\txt -> if txt==var
                                         then Just $ UntypedExpr $ getForall u subst
                                         else bound txt)
                                tps' rest body of
                             Just r -> r
                             Nothing -> error $ "smtlib2: Failed to parse quantifier construct "++show rest
                             ) decl
quantToExpr _ fun sort bound tps' [] body
  = lispToExpr fun sort bound tps' (\expr -> case gcast expr of
                                       Nothing -> error "smtlib2: Body of existential quantification isn't bool."
                                       Just r -> r
                                   ) (Just $ toSort (undefined::Bool) ()) body
quantToExpr _ _ _ _ _ (el:_) _ = error $ "smtlib2: Invalid element "++show el++" in quantifier construct."

data LetStruct where
  LetStruct :: SMTType a => SMTAnnotation a -> SMTExpr a -> (SMTExpr a -> LetStruct) -> LetStruct
  EndLet :: SMTType a => SMTExpr a -> LetStruct

parseLetStruct :: FunctionParser -> SortParser
                  -> (T.Text -> Maybe UntypedExpr)
                  -> Map.Map TyCon DeclaredType
                  -> Maybe Sort
                  -> [L.Lisp] -> L.Lisp -> LetStruct
parseLetStruct fun sort bound tps expected (L.List [L.Symbol name,expr]:rest) arg
  = case lispToExpr fun sort bound tps
         (\expr' -> LetStruct (extractAnnotation expr') expr' $
                    \sym -> parseLetStruct fun sort
                            (\txt -> if txt==name
                                     then Just $ UntypedExpr sym
                                     else bound txt) tps expected rest arg
         ) Nothing expr of
      Nothing -> error $ "smtlib2: Failed to parse argument in let-expression "++show expr
      Just x -> x
parseLetStruct fun sort bound tps expected [] arg
  = case lispToExpr fun sort bound tps EndLet expected arg of
    Nothing -> error $ "smtlib2: Failed to parse body of let-expression: "++show arg
    Just x -> x
parseLetStruct _ _ _ _ _ (el:_) _ = error $ "smtlib2: Invalid entry "++show el++" in let construct."

extractType :: (forall a. SMTType a => a -> b) -> LetStruct -> b
extractType f (EndLet x) = f (getUndef x)
extractType f (LetStruct _ _ g) = extractType f (g $ error "smtlib2: Don't evaluate the argument to the let-function.")

convertLetStructT :: SMTType a => LetStruct -> SMTExpr a
convertLetStructT (EndLet x) = case gcast x of
  Just x' -> x'
  Nothing -> error "smtlib2: Type error while converting let structure."
convertLetStructT (LetStruct ann x g) = Let ann x (\sym -> convertLetStructT (g sym))

convertLetStruct :: (forall a. SMTType a => SMTExpr a -> b) -> LetStruct -> b
convertLetStruct f x
  = extractType
    (\(_::t) -> f (convertLetStructT x :: SMTExpr t)) x

withFirstArgSort :: L.Lisp -> [Sort] -> (forall t. SMTType t => t -> SMTAnnotation t -> a) -> a
withFirstArgSort _ (s:rest) f = case s of
  BVSort i False -> if any (\sort -> case sort of
                               BVSort _ True -> True
                               _ -> False) rest
                    then withSort (BVSort i True) f
                    else withSort s f
  _ -> withSort s f
withFirstArgSort sym [] _ = error $ "smtlib2: Function "++show sym++" needs at least one argument."

nameParser :: L.Lisp -> FunctionParser' -> FunctionParser
nameParser name sub = FunctionParser (\sym _ _ -> if sym==name
                                                  then Just sub
                                                  else Nothing)

simpleParser :: (SMTFunction f,Unit (ArgAnnotation (SMTFunArg f)),Unit (SMTAnnotation (SMTFunRes f))) => f -> FunctionParser
simpleParser fun
  = let fsym = getFunctionSymbol fun unit
        (uargs,ures) = getFunUndef fun
    in nameParser fsym (DefinedParser
                        (toSorts uargs unit)
                        (toSort ures unit)
                        $ \f -> Just $ f fun)

commonFunctions :: FunctionParser
commonFunctions = mconcat
                  [eqParser
                  ,mapParser
                  ,ordOpParser
                  ,arithOpParser
                  ,minusParser
                  ,intArithParser
                  ,divideParser
                  ,absParser
                  ,logicParser
                  ,iteParser
                  ,distinctParser
                  ,toRealParser
                  ,toIntParser
                  ,bvCompParser
                  ,bvBinOpParser
                  ,bvUnOpParser
                  ,selectParser
                  ,storeParser
                  ,constArrayParser
                  ,concatParser
                  ,extractParser
                  ,sigParser]

eqParser,
  mapParser,
  ordOpParser,
  arithOpParser,
  minusParser,
  intArithParser,
  divideParser,
  absParser,
  logicParser,
  iteParser,
  distinctParser,
  toRealParser,
  toIntParser,
  bvCompParser,
  bvBinOpParser,
  bvUnOpParser,
  selectParser,
  storeParser,
  constArrayParser,
  concatParser,
  extractParser,
  sigParser :: FunctionParser
eqParser = nameParser (L.Symbol "=") $
           OverloadedParser (const $ Just $ toSort (undefined::Bool) ()) $
           \sort_arg _ f -> withFirstArgSort "=" sort_arg $
                            \(_::t) _ -> Just $ f (Eq :: SMTEq t)

mapParser = FunctionParser v
  where
    v (L.List [L.Symbol "_"
              ,L.Symbol "map"
              ,fun]) rec sort
#ifdef SMTLIB2_WITH_CONSTRAINTS
      = case parseFun rec fun rec sort of
        Nothing -> Nothing
        Just (DefinedParser _ ret_sig parse)
          -> Just $ OverloadedParser
            { deriveRetSort = \arg -> case arg of
                 ArraySort i _:_ -> Just (ArraySort i ret_sig)
                 _ -> error "smtlib2: map function must have arrays as arguments."
            , parseOverloaded = \_ ret f
                                 -> let idx_sort = case ret of
                                          ArraySort i _ -> i
                                          _ -> error "smtlib2: map function must have arrays as return type."
                                    in parse $ \(fun' :: g)
                                               -> withArgSort idx_sort $
                                                  \(_::i) _ -> let res = SMTMap fun' :: SMTMap g i r
                                                               in case getConstraint (Proxy :: Proxy (SMTFunArg g,i)) of
                                                                 Dict -> f res
            }
        Just _ -> error "smtlib2: map function can't handle overloaded functions."
#else
      = Just $ error "smtlib2: Compile smtlib2 with -fWithConstraints to enable parsing of map functions"
#endif
    v _ _ _ = Nothing

ordOpParser = FunctionParser $ \sym _ _ -> case sym of
  L.Symbol ">=" -> p sym Ge
  L.Symbol ">" -> p sym Gt
  L.Symbol "<=" -> p sym Le
  L.Symbol "<" -> p sym Lt
  _ -> Nothing
  where
    p :: L.Lisp -> (forall g. SMTOrdOp g) -> Maybe FunctionParser'
    p sym op = Just $ OverloadedParser (const $ Just $ toSort (undefined::Bool) ()) $
               \sort_arg _ f -> withFirstArgSort sym sort_arg $ \(_::t) _ -> Just $ f (op::SMTOrdOp t)

arithOpParser = FunctionParser $ \sym _ _ -> case sym of
  L.Symbol "+" -> Just $ OverloadedParser (\sorts -> Just (head sorts)) $
                  \_ sort_ret f
                  -> withSort sort_ret $ \(_::t) _ -> Just $ f (Plus::SMTArithOp t)
  L.Symbol "*" -> Just $ OverloadedParser (\sorts -> Just (head sorts)) $
                  \_ sort_ret f
                  -> withSort sort_ret $ \(_::t) _ -> Just $ f (Mult::SMTArithOp t)
  _ -> Nothing

minusParser = nameParser (L.Symbol "-")
              (OverloadedParser (\sorts -> Just (head sorts)) $
               \sort_arg _ f -> case sort_arg of
                 [] -> error "smtlib2: minus function needs at least one argument"
                 [s] -> withSort s $ \(_::t) _ -> Just $ f (Neg::SMTNeg t)
                 (s:_) -> withSort s $ \(_::t) _ -> Just $ f (Minus::SMTMinus t))

intArithParser = mconcat [simpleParser Div
                         ,simpleParser Mod
                         ,simpleParser Rem]

divideParser = simpleParser Divide

absParser = nameParser (L.Symbol "abs")
            (OverloadedParser (\sorts -> Just $ head sorts) $
             \_ sort_ret f
             -> withSort sort_ret $ \(_::t) _ -> Just $ f (Abs::SMTAbs t))

logicParser = mconcat $
              (simpleParser Not)
              :[ nameParser (L.Symbol name)
                 (OverloadedParser
                  (const $ Just $ toSort (undefined::Bool) ())
                  $ \_ _ f -> Just $ f p)
               | (name,p) <- [("and",And),("or",Or),("xor",XOr),("=>",Implies)]]

distinctParser = nameParser (L.Symbol "distinct")
                 (OverloadedParser
                  (const $ Just $ toSort (undefined::Bool) ()) $
                  \sort_arg _ f -> withFirstArgSort "distinct" sort_arg $ \(_::t) _ -> Just $ f (Distinct::SMTDistinct t))

toRealParser = simpleParser ToReal
toIntParser = simpleParser ToInt

iteParser = nameParser (L.Symbol "ite")
            (OverloadedParser
             (\sorts -> case sorts of
                 [_,s,_] -> Just s
                 _ -> error $ "smtlib2: Wrong number of arguments to ite (expected 3, got "++show (length sorts)++".") $
             \_ sort_ret f -> withSort sort_ret $ \(_::t) _ -> Just $ f (ITE :: SMTITE t))

bvCompParser = FunctionParser $ \sym _ _ -> case sym of
  L.Symbol "bvule" -> p BVULE
  L.Symbol "bvult" -> p BVULT
  L.Symbol "bvuge" -> p BVUGE
  L.Symbol "bvugt" -> p BVSLE
  L.Symbol "bvsle" -> p BVSLE
  L.Symbol "bvslt" -> p BVSLT
  L.Symbol "bvsge" -> p BVSGE
  L.Symbol "bvsgt" -> p BVSGT
  _ -> Nothing
  where
    p :: (forall g. SMTBVComp g) -> Maybe FunctionParser'
    p op = Just $ OverloadedParser (const $ Just $ toSort (undefined::Bool) ()) $
           \sort_arg _ f -> case sort_arg of
#ifdef SMTLIB2_WITH_DATAKINDS
             (BVSort i False:_) -> reifyNat i $ \(_::Proxy n) -> Just $ f (op::SMTBVComp (BVTyped n))
#else
             (BVSort i False:_) -> reifyNat i $ \(_::n) -> Just $ f (op::SMTBVComp (BVTyped n))
#endif
             (BVSort _ True:_) -> Just $ f (op::SMTBVComp BVUntyped)
             _ -> error "smtlib2: Bitvector comparision needs bitvector arguments."

bvBinOpParser = FunctionParser $ \sym _ _ -> case sym of
  L.Symbol "bvadd" -> p BVAdd
  L.Symbol "bvsub" -> p BVSub
  L.Symbol "bvmul" -> p BVMul
  L.Symbol "bvurem" -> p BVURem
  L.Symbol "bvsrem" -> p BVSRem
  L.Symbol "bvudiv" -> p BVUDiv
  L.Symbol "bvsdiv" -> p BVSDiv
  L.Symbol "bvshl" -> p BVSHL
  L.Symbol "bvlshr" -> p BVLSHR
  L.Symbol "bvashr" -> p BVASHR
  L.Symbol "bvxor" -> p BVXor
  L.Symbol "bvand" -> p BVAnd
  L.Symbol "bvor" -> p BVOr
  _ -> Nothing
  where
    p :: (forall g. SMTBVBinOp g) -> Maybe FunctionParser'
    p op = Just $ OverloadedParser (Just . head) $
           \_ sort_ret f -> case sort_ret of
#ifdef SMTLIB2_WITH_DATAKINDS
              BVSort i False -> reifyNat i (\(_::Proxy n) -> Just $ f (op::SMTBVBinOp (BVTyped n)))
#else
              BVSort i False -> reifyNat i (\(_::n) -> Just $ f (op::SMTBVBinOp (BVTyped n)))
#endif
              BVSort _ True -> Just $ f (op::SMTBVBinOp BVUntyped)
              _ -> Nothing

bvUnOpParser = FunctionParser $ \sym _ _ -> case sym of
  L.Symbol "bvnot"
    -> Just $ OverloadedParser (Just . head) $
       \_ sort_ret f -> case sort_ret of
#ifdef SMTLIB2_WITH_DATAKINDS
        BVSort i False -> reifyNat i $ \(_::Proxy n) -> Just $ f (BVNot::SMTBVUnOp (BVTyped n))
#else
        BVSort i False -> reifyNat i $ \(_::n) -> Just $ f (BVNot::SMTBVUnOp (BVTyped n))
#endif
        BVSort _ True -> Just $ f (BVNot::SMTBVUnOp BVUntyped)
        _ -> Nothing
  L.Symbol "bvneg"
    -> Just $ OverloadedParser (Just . head) $
      \_ sort_ret f -> case sort_ret of
#ifdef SMTLIB2_WITH_DATAKINDS
        BVSort i False -> reifyNat i $ \(_::Proxy n) -> Just $ f (BVNeg::SMTBVUnOp (BVTyped n))
#else
        BVSort i False -> reifyNat i $ \(_::n) -> Just $ f (BVNeg::SMTBVUnOp (BVTyped n))
#endif
        BVSort _ True -> Just $ f (BVNeg::SMTBVUnOp BVUntyped)
        _ -> Nothing
  _ -> Nothing

selectParser = nameParser (L.Symbol "select")
               (OverloadedParser (\sort_arg -> case sort_arg of
                                     (ArraySort _ vsort:_) -> Just vsort
                                     _ -> error "smtlib2: Wrong arguments for select function.") $
                \sort_arg sort_ret f -> case sort_arg of
                  (ArraySort isort1 _:_) -> withArgSort isort1 $
                                            \(_::i) _ -> withSort sort_ret $
                                                         \(_::v) _ -> Just $ f (Select::SMTSelect i v)
                  _ -> error "smtlib2: Wrong arguments for select function.")

storeParser = nameParser (L.Symbol "store")
              (OverloadedParser (\sort_arg -> case sort_arg of
                                    s:_ -> Just s
                                    _ -> error "smtlib2: Wrong arguments for store function.") $
               \_ sort_ret f -> case sort_ret of
                 ArraySort idx val -> withArraySort idx val $ \(_::SMTArray i v) _ -> Just $ f (Store::SMTStore i v)
                 _ -> error "smtlib2: Wrong arguments for store function.")

constArrayParser = FunctionParser g
  where
    g (L.List [L.Symbol "as"
              ,L.Symbol "const"
              ,s]) _ sort
      = case parseSort sort s sort of
        Just rsort@(ArraySort idx val)
          -> Just $ DefinedParser [val] rsort $
             \f -> withArraySort idx val $
                   \(_::SMTArray i v) (i_ann,_)
                   -> Just $ f (ConstArray i_ann::SMTConstArray i v)
        _ -> Nothing
    g _ _ _ = Nothing

concatParser = nameParser (L.Symbol "concat")
               (OverloadedParser
                (\args' -> let lenSum = sum $ fmap (\(BVSort i _) -> i) args'
                               untypedRes = any (\(BVSort _ isUntyped) -> isUntyped) args'
                           in Just $ BVSort lenSum untypedRes)
                (\sort_arg _ f -> case sort_arg of
                    [BVSort i1 False,BVSort i2 False]
                      -> reifySum i1 i2 $
#ifdef SMTLIB2_WITH_DATAKINDS
                        \(_::Proxy n1) (_::Proxy n2) _
#else
                        \(_::n1) (_::n2) _
#endif
                          -> Just $ f (BVConcat::SMTConcat (BVTyped n1) (BVTyped n2))
                    [BVSort _ True,BVSort i2 False]
                      -> reifyNat i2 $
#ifdef SMTLIB2_WITH_DATAKINDS
                        \(_::Proxy n2)
#else
                        \(_::n2)
#endif
                          -> Just $ f (BVConcat::SMTConcat BVUntyped (BVTyped n2))
                    [BVSort i1 False,BVSort _ True]
                      -> reifyNat i1 $
#ifdef SMTLIB2_WITH_DATAKINDS
                        \(_::Proxy n1)
#else
                        \(_::n1)
#endif
                          -> Just $ f (BVConcat::SMTConcat (BVTyped n1) BVUntyped)
                    [BVSort _ True,BVSort _ True]
                      -> Just $ f (BVConcat::SMTConcat BVUntyped BVUntyped)
                    _ -> Nothing))

extractParser = FunctionParser g
  where
    g (L.List [L.Symbol "_"
              ,L.Symbol "extract"
              ,L.Number (L.I u)
              ,L.Number (L.I l)]) _ _
      = Just $ OverloadedParser
        (\args' -> case args' of
            [BVSort t untyped] -> if u < t && l >= 0 && l <= u
                                  then Just $ BVSort (u-l+1) untyped
                                  else error "smtlib2: Invalid parameters for extract."
            _ -> error "smtlib2: Invalid parameters for extract.")
        (\sort_arg sort_ret f -> case sort_arg of
            [BVSort t untA] -> case sort_ret of
              BVSort r untR -> if r+l == u+1 && (untR == untA)
                                then reifyNat l $
#ifdef SMTLIB2_WITH_DATAKINDS
                                     \(_::Proxy start)
                                      -> reifyNat (u-l+1) $
                                         \(_::Proxy len)
                                          -> if not untR
                                             then reifyNat t $
                                                   \(_::Proxy tp)
                                                    -> Just $ f (BVExtract::SMTExtract (BVTyped tp) start len)
                                             else Just $ f (BVExtract::SMTExtract BVUntyped start len)
#else
                                     \(_::start)
                                      -> reifyNat (u-l+1) $
                                         \(_::len)
                                          -> if not untR
                                             then reifyNat t $
                                                   \(_::tp) -> Just $ f (BVExtract::SMTExtract (BVTyped tp) start len)
                                             else Just $ f (BVExtract::SMTExtract BVUntyped start len)
#endif
                                else error "smtlib2: Invalid parameters for extract."
              _ -> error "smtlib2: Wrong return type for extract."
            _ -> error "smtlib2: Wrong argument type for extract.")
    g _ _ _ = Nothing

sigParser = FunctionParser g
  where
    g (L.List [fsym,L.List sig,ret]) rec sort = do
      rsig <- mapM (\l -> parseSort sort l sort) sig
      rret <- parseSort sort ret sort
      parser <- parseFun rec fsym rec sort
      return $ DefinedParser rsig rret $
        \f -> case parser of
          OverloadedParser _ parse -> parse rsig rret f
          DefinedParser _ _ parse -> parse f
    g _ _ _ = Nothing

instance (SMTValue a) => LiftArgs (SMTExpr a) where
  type Unpacked (SMTExpr a) = a
  liftArgs = Const
  unliftArgs = getValue
