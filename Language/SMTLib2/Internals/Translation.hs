{-# LANGUAGE RankNTypes,TypeFamilies,OverloadedStrings,GADTs,FlexibleContexts #-}
module Language.SMTLib2.Internals.Translation where

import Language.SMTLib2.Internals
import Language.SMTLib2.Internals.Instances (extractAnnotation)

import qualified Data.AttoLisp as L
import Data.Typeable
import Data.Text as T hiding (foldl1)
import Data.Word
import Data.Array
import qualified Data.Map as Map (Map,lookup,elems)
import Data.List (genericLength)

import Data.Unit

instance L.ToLisp (SMTExpr t) where
  toLisp e = fst $ exprToLisp e 0

instance Show (SMTExpr t) where
  show x = show $ fst (exprToLisp x 0)

-- | After a successful 'checkSat' call, extract values from the generated model.
--   The 'ProduceModels' option must be enabled for this.
getValue :: SMTValue t => SMTExpr t -> SMT t
getValue expr = do
  let ann = case expr of
        Var _ a -> a
        Const _ a -> a
        _ -> error "Can't use getValue on complex expressions. Use getValue' instead."
  getValue' ann expr
  
-- | Extract values of compound expressions from the generated model.
getValue' :: SMTValue t => SMTAnnotation t -> SMTExpr t -> SMT t
getValue' ann expr = do
  res <- fmap removeLets $ getRawValue expr
  case unmangle res ann of
    Nothing -> error $ "Couldn't unmangle "++show res
    Just r -> return r

getRawValue :: SMTType t => SMTExpr t -> SMT L.Lisp
getRawValue expr = do
  clearInput
  putRequest $ L.List [L.Symbol "get-value"
                      ,L.List [L.toLisp expr]]
  val <- parseResponse
  case val of
    L.List [L.List [_,res]] -> return res
    _ -> error $ "unknown response to get-value: "++show val

-- | Define a new function with a body
defFun :: (Args a,SMTType r,Unit (ArgAnnotation a),Unit (SMTAnnotation r)) => (a -> SMTExpr r) -> SMT (SMTFun a r)
defFun = defFunAnn unit unit

-- | Define a new constant
defConst :: (SMTType r,Unit (SMTAnnotation r)) => SMTExpr r -> SMT (SMTExpr r)
defConst = defConstAnn unit

-- | Define a new constant with a type annotation.
defConstAnn :: (SMTType r) => SMTAnnotation r -> SMTExpr r -> SMT (SMTExpr r)
defConstAnn ann e = do
  f <- defFunAnn () ann (const e)
  return $ App f ()

-- | Define a new function with a body and custom type annotations for arguments and result.
defFunAnnNamed :: (Args a,SMTType r) => String -> ArgAnnotation a -> SMTAnnotation r -> (a -> SMTExpr r) -> SMT (SMTFun a r)
defFunAnnNamed name ann_arg ann_res f = do
  fname <- freeName name
  (names,_,_) <- getSMT
  let c_args = case Map.lookup "arg" names of
        Nothing -> 0
        Just n -> n

      res = SMTFun fname ann_arg ann_res
      
      (_,rtp) = getFunUndef res
      
      (au,tps,c_args') = createArgs ann_arg (c_args+1)
      
      (expr',_) = exprToLisp (f au) c_args'
  defineFun fname tps (getSort rtp ann_res) expr'
  return res

-- | Like `defFunAnnNamed`, but defaults the function name to "fun".
defFunAnn :: (Args a,SMTType r) => ArgAnnotation a -> SMTAnnotation r -> (a -> SMTExpr r) -> SMT (SMTFun a r)
defFunAnn = defFunAnnNamed "fun"

-- | Extract all values of an array by giving the range of indices.
unmangleArray :: (LiftArgs i,Ix (Unpacked i),SMTValue v,
                  --Unit (SMTAnnotation (Unpacked i)),
                  Unit (ArgAnnotation i)) 
                 => (Unpacked i,Unpacked i) 
                 -> SMTExpr (SMTArray i v) 
                 -> SMT (Array (Unpacked i) v)
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
    in (L.List [L.Symbol "_",L.Symbol "as-array",f'],c)
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
exprToLisp (App fun x) c = let arg_ann = extractArgAnnotation x
                               l = getFunctionSymbol fun arg_ann
                               ~(x',c1) = unpackArgs (\e _ i -> exprToLisp e i) x
                                          arg_ann c
                           in if Prelude.null x'
                              then (l,c1)
                              else (L.List $ l:x',c1)
exprToLisp (Named expr name) c = let (expr',c') = exprToLisp expr c
                                 in (L.List [L.Symbol "!",expr',L.Symbol ":named",L.Symbol name],c')
exprToLisp (InternalFun arguments) c = (L.List (L.Symbol "_":arguments),c)
exprToLisp Undefined _ = error "Language.SMTLib2.Internals.Translation.exprToLisp: Called on Undefined expression."

withUndef :: TypeRep -> (forall a. (SMTValue a,Typeable a,SMTAnnotation a ~ ()) => a -> b) -> b
withUndef rep f
  | rep == typeOf (undefined :: Bool) = f (undefined::Bool)
  | rep == typeOf (undefined :: Integer) = f (undefined::Integer)
  | rep == typeOf (undefined :: Word8) = f (undefined::Word8)
  | rep == typeOf (undefined :: Word16) = f (undefined::Word16)
  | rep == typeOf (undefined :: Word32) = f (undefined::Word32)
  | rep == typeOf (undefined :: Word64) = f (undefined::Word64)
  | otherwise = error $ "Language.SMTLib2.Instances.withUndef not implemented for "++show rep

asType :: a -> g a -> g a
asType = const id

binT :: (SMTValue b1,Typeable b1,
         SMTValue b2,Typeable b2,
         SMTValue c,Typeable c,
         SMTAnnotation b1 ~ (),
         SMTAnnotation b2 ~ (),
         SMTAnnotation c ~ ()) 
        => (forall a. (SMTValue a,Typeable a,SMTAnnotation a ~ ()) => SMTExpr a -> d)
        -> (SMTExpr b1 -> SMTExpr b2 -> SMTExpr c) 
        -> (T.Text -> Maybe UntypedExpr)
        -> Map.Map TyCon DeclaredType -> (T.Text -> TypeRep) -> L.Lisp -> L.Lisp -> Maybe d
binT f con bound tps g lhs rhs 
  = let lhs' = lispToExprT bound tps () g lhs
        rhs' = lispToExprT bound tps () g rhs
    in Just $ f (con lhs' rhs')

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

data UntypedExpr where
  UntypedExpr :: SMTType a => SMTExpr a -> UntypedExpr

entype :: (forall a. SMTType a => SMTExpr a -> b) -> UntypedExpr -> b
entype f (UntypedExpr x) = f x

lispToExprU :: (forall a. SMTType a => SMTExpr a -> b)
               -> (T.Text -> Maybe UntypedExpr)
               -> Map.Map TyCon DeclaredType
               -> (T.Text -> TypeRep)
               -> L.Lisp -> Maybe b
lispToExprU f bound tps g l
  = firstJust $
    [ unmangleDeclared f tp l | tp <- Map.elems tps ] ++
    [case l of
        L.Symbol name -> let (tycon,_) = splitTyConApp (g name)
                         in case bound name of
                           Nothing -> case Map.lookup tycon tps of
                             Nothing -> Nothing
                             Just decl -> Just $ createVarDeclared f decl name
                           Just subst -> entype (\subst' ->  Just $ f subst') subst
        L.List [L.Symbol "=",lhs,rhs] 
          -> let lhs' = lispToExprU (\lhs' -> let rhs' = lispToExprT bound tps (extractAnnotation lhs') g rhs
                                              in f (App (Eq 2) [lhs',rhs'])
                                    ) bound tps g lhs
             in case lhs' of
               Just r -> Just r
               Nothing -> lispToExprU (\rhs' -> let lhs'' = lispToExprT bound tps (extractAnnotation rhs') g lhs
                                                in f (App (Eq 2) [lhs'',rhs'])
                                      ) bound tps g rhs
        L.List [L.Symbol ">=",lhs,rhs] -> binT f ((.>=.)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Bool) bound tps g lhs rhs
        L.List [L.Symbol ">",lhs,rhs] -> binT f ((.>.)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Bool) bound tps g lhs rhs
        L.List [L.Symbol "<=",lhs,rhs] -> binT f ((.<=.)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Bool) bound tps g lhs rhs
        L.List [L.Symbol "<",lhs,rhs] -> binT f ((.<.)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Bool) bound tps g lhs rhs
        L.List (L.Symbol "distinct":first:rest)
          -> lispToExprU (\first' -> let rest' = fmap (lispToExprT bound tps (extractAnnotation first') g) rest
                                     in f $ App Distinct (first':rest')
                         ) bound tps g first
        L.List (L.Symbol "+":arg) -> Just $ f $ foldl1 ((+)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer) $ 
                                     fmap (lispToExprT bound tps () g) arg
        L.List [L.Symbol "-",lhs,rhs] -> binT f ((-)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer) bound tps g lhs rhs
        L.List (L.Symbol "*":arg) -> Just $ f $ foldl1 ((*)::SMTExpr Integer -> SMTExpr Integer -> SMTExpr Integer) $
                                     fmap (lispToExprT bound tps () g) arg
        L.List [L.Symbol "div",lhs,rhs] -> binT f (curry $ App Div) bound tps g lhs rhs
        L.List [L.Symbol "mod",lhs,rhs] -> binT f (curry $ App Mod) bound tps g lhs rhs
        L.List [L.Symbol "rem",lhs,rhs] -> binT f (curry $ App Rem) bound tps g lhs rhs
        L.List [L.Symbol "/",lhs,rhs] -> binT f (curry $ App Divide) bound tps g lhs rhs
        L.List [L.Symbol "-",arg] -> Just $ f $ App Neg (lispToExprT bound tps () g arg :: SMTExpr Integer)
        L.List [L.Symbol "abs",arg] -> Just $ f $ App Abs (lispToExprT bound tps () g arg :: SMTExpr Integer)
        L.List [L.Symbol "to_real",arg] 
          -> Just $ f $ App ToReal (lispToExprT bound tps () g arg)
        L.List [L.Symbol "to_int",arg] 
          -> Just $ f $ App ToInt (lispToExprT bound tps () g arg)
        L.List [L.Symbol "ite",cond,lhs,rhs]
          -> let cond' = lispToExprT bound tps () g cond
             in case lispToExprU (\lhs' -> let rhs' = lispToExprT bound tps (extractAnnotation lhs') g rhs
                                           in f (App ITE (cond',lhs',rhs'))
                                 ) bound tps g lhs of
                  Just r -> Just r
                  Nothing -> lispToExprU (\rhs' -> let lhs'' = lispToExprT bound tps (extractAnnotation rhs') g lhs
                                                   in f (App ITE (cond',lhs'',rhs'))
                                         ) bound tps g rhs
        L.List (L.Symbol "and":arg) -> Just $ f $ 
                                       App And $
                                       fmap (lispToExprT bound tps () g) arg
        L.List (L.Symbol "or":arg) -> Just $ f $
                                      App Or $
                                      fmap (lispToExprT bound tps () g) arg
        L.List (L.Symbol "xor":arg)
          -> Just $ f $ App XOr $ fmap (lispToExprT bound tps () g) arg
        L.List (L.Symbol "=>":arg) 
          -> Just $ f $ App Implies $ fmap (lispToExprT bound tps () g) arg
        L.List [L.Symbol "not",arg] -> Just $ f $ App Not (lispToExprT bound tps () g arg :: SMTExpr Bool)
        L.List [L.Symbol "bvule",lhs,rhs] 
          -> Just $ f $ binBV (curry $ App BVULE) bound tps g lhs rhs
        L.List [L.Symbol "bvult",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVULT) bound tps g lhs rhs
        L.List [L.Symbol "bvuge",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVUGE) bound tps g lhs rhs
        L.List [L.Symbol "bvugt",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVUGT) bound tps g lhs rhs
        L.List [L.Symbol "bvsle",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVSLE) bound tps g lhs rhs
        L.List [L.Symbol "bvslt",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVSLT) bound tps g lhs rhs
        L.List [L.Symbol "bvsge",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVSGE) bound tps g lhs rhs
        L.List [L.Symbol "bvsgt",lhs,rhs]
          -> Just $ f $ binBV (curry $ App BVSGT) bound tps g lhs rhs
        L.List [L.Symbol "forall",L.List args,body] -> Just $ f $ quantToExpr Forall bound tps g args body
        L.List [L.Symbol "exists",L.List args,body] -> Just $ f $ quantToExpr Exists bound tps g args body
        L.List [L.Symbol "let",L.List args,body] -> Just $ convertLetStruct f (parseLetStruct bound tps g args body)
        L.List (L.Symbol fn:arg) -> Just $ fnToExpr f bound tps g fn arg
        _ -> Nothing
    ]

parseLetStruct :: (T.Text -> Maybe UntypedExpr)
                 -> Map.Map TyCon DeclaredType
                 -> (T.Text -> TypeRep) 
                 -> [L.Lisp] -> L.Lisp -> LetStruct
parseLetStruct bound tps g (L.List [L.Symbol name,expr]:rest) arg
  = case lispToExprU (\expr' -> LetStruct (extractAnnotation expr') expr' $
                                \sym -> parseLetStruct (\txt -> if txt==name
                                                                then Just $ UntypedExpr expr'
                                                                else bound txt) tps
                                        (\txt -> if txt==name
                                                 then typeOf $ getUndef $ expr'
                                                 else g txt) rest arg
                     ) bound tps g expr of
      Nothing -> error $ "smtlib2: Failed to parse argument in let-expression "++show expr
      Just x -> x
parseLetStruct bound tps g [] arg = case lispToExprU EndLet bound tps g arg of
  Nothing -> error $ "smtlib2: Failed to parse body of let-expression: "++show arg
  Just x -> x

data LetStruct where
  LetStruct :: SMTType a => SMTAnnotation a -> SMTExpr a -> (SMTExpr a -> LetStruct) -> LetStruct
  EndLet :: SMTType a => SMTExpr a -> LetStruct

extractType :: (forall a. SMTType a => a -> b) -> LetStruct -> b
extractType f (EndLet x) = f (getUndef x)
extractType f (LetStruct ann x g) = extractType f (g $ error "smtlib2: Don't evaluate the argument to the let-function.")

convertLetStructT :: SMTType a => LetStruct -> SMTExpr a
convertLetStructT (EndLet x) = case gcast x of
  Just x' -> x'
convertLetStructT (LetStruct ann x g) = Let ann x (\sym -> convertLetStructT (g sym))

convertLetStruct :: (forall a. SMTType a => SMTExpr a -> b) -> LetStruct -> b
convertLetStruct f x 
  = extractType 
    (\u -> f (assertEq u (convertLetStructT x))) x
  where
    assertEq :: a -> SMTExpr a -> SMTExpr a
    assertEq _ x = x
                                     
asBV :: Typeable a => (forall b. (SMTBV b,Typeable b) => SMTExpr b -> c) -> SMTExpr a -> c
asBV f e = case (gcast e :: Maybe (SMTExpr Word8)) of
  Just r -> f r
  Nothing -> case (gcast e :: Maybe (SMTExpr Word16)) of
    Just r -> f r
    Nothing -> case (gcast e :: Maybe (SMTExpr Word32)) of
      Just r -> f r
      Nothing -> case (gcast e :: Maybe (SMTExpr Word64)) of
        Just r -> f r
        Nothing -> error $ "Cannot treat expression of type "++show (typeOf e)++" as bitvector"

fnToExpr :: (forall a. (SMTValue a,Typeable a,SMTAnnotation a ~ ()) => SMTExpr a -> b)
            -> (T.Text -> Maybe UntypedExpr)
            -> Map.Map TyCon DeclaredType
            -> (T.Text -> TypeRep)
            -> T.Text -> [L.Lisp] -> b
fnToExpr f bound tps g fn arg = case splitTyConApp $ g fn of
  (_,[targs,res]) -> withUndef res $ \res' -> case splitTyConApp targs of
    (_,rargs) -> case rargs of
      [] -> let [a0] = arg 
            in withUndef targs $ 
               \t0' -> f $ asType res' $ App (SMTFun fn undefined undefined) (asType t0' $ lispToExprT bound tps () g a0)
      [t0,t1] -> let [a0,a1] = arg 
                 in withUndef t0 $ 
                    \t0' -> withUndef t1 $ 
                            \t1' -> let p0 = lispToExprT bound tps () g a0
                                        p1 = lispToExprT bound tps () g a1
                                    in f $ asType res' $ App (SMTFun fn undefined undefined) (asType t0' p0,asType t1' p1)
      [t0,t1,t2] -> let [a0,a1,a2] = arg 
                    in withUndef t0 $ 
                       \t0' -> withUndef t1 $ 
                               \t1' -> withUndef t2 $ 
                                       \t2' -> let p0 = lispToExprT bound tps () g a0
                                                   p1 = lispToExprT bound tps () g a1
                                                   p2 = lispToExprT bound tps () g a2
                                               in f $ asType res' $ App (SMTFun fn undefined undefined) (asType t0' p0,asType t1' p1,asType t2' p2)
      _ -> error "Language.SMTLib2.Internals.Translation.fnToExpr: Invalid number of function arguments given (more than 3)."
  _ -> error $ "Language.SMTLib2.Internals.Translation.fnToExpr: Invalid function type "++(show $ g fn)++" given to function "++show fn++"."

fgcast :: (Typeable a,Typeable b) => L.Lisp -> c a -> c b
fgcast l x = case gcast x of
  Just r -> r
  Nothing -> error $ "Type error in expression "++show l

binBV :: (forall a. (SMTBV a,Typeable a) => SMTExpr a -> SMTExpr a -> SMTExpr b) 
         -> (T.Text -> Maybe UntypedExpr)
         -> Map.Map TyCon DeclaredType -> (T.Text -> TypeRep) -> L.Lisp -> L.Lisp -> SMTExpr b
binBV f bound tps g lhs rhs
  = let r0 = lispToExprU (asBV (\lhs0 -> let rhs0 = lispToExprT bound tps (extractAnnotation lhs0) g rhs
                                         in f lhs0 rhs0
                               )) bound tps g lhs
    in case r0 of
      Just r -> r
      Nothing -> let r1 = lispToExprU (asBV (\rhs1 -> let lhs1 = lispToExprT bound tps (extractAnnotation rhs1) g lhs
                                                      in f lhs1 rhs1
                                            )) bound tps g rhs
                 in case r1 of
                   Just r -> r
                   Nothing -> error $ "Parsing bitvector expression failed"

lispToExprT :: (SMTType a,Typeable a) => 
               (T.Text -> Maybe UntypedExpr)
               -> Map.Map TyCon DeclaredType 
               -> SMTAnnotation a -> (T.Text -> TypeRep) -> L.Lisp -> SMTExpr a
lispToExprT bound tps ann g l 
  = withWitness $ \u -> 
  let (tycon,_) = splitTyConApp $ typeOf u
  in case (do 
              decl <- Map.lookup tycon tps
              withDeclaredValueType (\u' ann' -> do
                                        c <- unmangle l ann'
                                        gcast $ Const (mkEq u' c) ann'
                                    ) decl) of
       Just (Just res) -> res
       _ -> case l of
         L.Symbol name -> case bound name of
           Nothing -> Var name ann
           Just expr -> entype (\expr' -> case gcast expr' of 
                                   Nothing -> error $ "smtlib2: Variable "++show name++" is not of type "++show (typeOf u)++"."
                                   Just x -> x)
                        expr
         L.List [L.Symbol "=",lhs,rhs] 
           -> let lhs' = lispToExprU (\lhs' -> let rhs' = lispToExprT bound tps (extractAnnotation lhs') g rhs
                                               in fgcast l $ App (Eq 2) [lhs',rhs']
                                     ) bound tps g lhs
              in case lhs' of
                Just r -> r
                Nothing -> let rhs' = lispToExprU 
                                      (\rhs' -> let lhs'' = lispToExprT bound tps (extractAnnotation rhs') g lhs
                                                in fgcast l $ App (Eq 2) [lhs'',rhs']
                                      ) bound tps g rhs
                           in case rhs' of
                             Just r -> r
                             Nothing -> error $ "Failed to parse expression "++show l
         L.List [L.Symbol ">",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                              r' = lispToExprT bound tps () g rhs
                                          in fgcast l $ App Gt (l' :: SMTExpr Integer,r')
         L.List [L.Symbol ">=",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                               r' = lispToExprT bound tps () g rhs
                                           in fgcast l $ App Ge (l' :: SMTExpr Integer,r')
         L.List [L.Symbol "<",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                              r' = lispToExprT bound tps () g rhs
                                          in fgcast l $ App Lt (l' :: SMTExpr Integer,r')
         L.List [L.Symbol "<=",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                               r' = lispToExprT bound tps () g rhs
                                           in fgcast l $ App Le (l' :: SMTExpr Integer,r')
         L.List (L.Symbol "+":arg) -> let arg' = fmap (lispToExprT bound tps () g) arg
                                      in fgcast l $ foldl1 (+) (arg' :: [SMTExpr Integer])
         L.List [L.Symbol "-",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                              r' = lispToExprT bound tps () g rhs
                                          in fgcast l $ App Minus (l' :: SMTExpr Integer,r')
         L.List (L.Symbol "*":arg) -> let arg' = fmap (lispToExprT bound tps () g) arg
                                      in fgcast l $ foldl1 (*) (arg' :: [SMTExpr Integer])
         L.List [L.Symbol "/",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                              r' = lispToExprT bound tps () g rhs
                                          in fgcast l $ App Div (l',r')
         L.List [L.Symbol "div",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                                r' = lispToExprT bound tps () g rhs
                                            in fgcast l $ App Div (l',r')
         L.List [L.Symbol "mod",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                                r' = lispToExprT bound tps () g rhs
                                            in fgcast l $ App Mod (l',r')
         L.List [L.Symbol "rem",lhs,rhs] -> let l' = lispToExprT bound tps () g lhs
                                                r' = lispToExprT bound tps () g rhs
                                            in fgcast l $ App Rem (l',r')
         L.List [L.Symbol "to_real",arg] 
           -> let arg' = lispToExprT bound tps () g arg
              in fgcast l $ App ToReal arg'
         L.List [L.Symbol "to_int",arg] 
           -> let arg' = lispToExprT bound tps () g arg
              in fgcast l $ App ToInt arg'
         L.List (L.Symbol "and":arg)
           -> let arg' = fmap (lispToExprT bound tps () g) arg
              in fgcast l $ App And arg'
         L.List (L.Symbol "or":arg) 
           -> let arg' = fmap (lispToExprT bound tps () g) arg
              in fgcast l $ App Or arg'
         L.List (L.Symbol "xor":arg)
           -> let arg' = fmap (lispToExprT bound tps () g) arg
              in fgcast l $ App XOr arg'
         L.List [L.Symbol "ite",cond,lhs,rhs]
           -> let c' = lispToExprT bound tps () g cond
                  lhs' = lispToExprU (\lhs' -> let rhs' = lispToExprT bound tps (extractAnnotation lhs') g rhs
                                               in fgcast l $ App ITE (c',lhs',rhs')
                                     ) bound tps g lhs
                  rhs' = lispToExprU (\rhs' -> let lhs'' = lispToExprT bound tps (extractAnnotation rhs') g lhs
                                               in fgcast l $ App ITE (c',lhs'',rhs')
                                     ) bound tps g rhs
              in case lhs' of
                Just r -> r
                Nothing -> case rhs' of
                  Just r -> r
                  Nothing -> error $ "Failed to parse expression "++show l
         L.List [L.Symbol "not",arg] -> fgcast l $ App Not $ lispToExprT bound tps () g arg
         L.List [L.Symbol "let",L.List syms,arg] -> letToExpr bound tps g ann syms arg
         L.List [L.Symbol "bvule",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVULE) bound tps g lhs rhs
         L.List [L.Symbol "bvult",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVULT) bound tps g lhs rhs
         L.List [L.Symbol "bvuge",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVUGE) bound tps g lhs rhs
         L.List [L.Symbol "bvugt",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVUGT) bound tps g lhs rhs
         L.List [L.Symbol "bvsle",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVSLE) bound tps g lhs rhs
         L.List [L.Symbol "bvslt",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVSLT) bound tps g lhs rhs
         L.List [L.Symbol "bvsge",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVSGE) bound tps g lhs rhs
         L.List [L.Symbol "bvsgt",lhs,rhs]
           -> fgcast l $ binBV (curry $ App BVSGT) bound tps g lhs rhs
         L.List [L.Symbol "forall",L.List vars,body] -> fgcast l $ quantToExpr Forall bound tps g vars body
         L.List [L.Symbol "exists",L.List vars,body] -> fgcast l $ quantToExpr Exists bound tps g vars body
         L.List (L.Symbol fn:arg) -> fnToExpr (fgcast l) bound tps g fn arg
         {-L.List [L.List (L.Symbol "_":arg),expr] 
           -> fgcast l $ App (InternalFun arg) $
              lispToExprT bound tps () g expr-}
         _ -> error $ "Cannot parse "++show l
  where
    letToExpr :: SMTType a => 
                 (T.Text -> Maybe UntypedExpr) 
                 -> Map.Map TyCon DeclaredType -> (T.Text -> TypeRep)
                 -> SMTAnnotation a
                 -> [L.Lisp] -> L.Lisp -> SMTExpr a
    letToExpr bound tps' g' ann (L.List [L.Symbol name,expr]:rest) arg
      = let res = lispToExprU 
                  (\expr' -> let ann' = extractAnnotation expr'
                             in Let ann' expr'
                                (\sym -> letToExpr (\txt -> if txt==name
                                                            then Just (UntypedExpr sym)
                                                            else bound txt)
                                         tps' (\txt -> if txt==name
                                                       then typeOf $ getUndef expr'
                                                       else g' txt) ann rest arg)
                  ) bound tps' g' expr
        in case res of
          Just r -> r
          Nothing -> error $ "Unparseable expression "++show expr++" in let expression"
    letToExpr bound tps' g' ann [] arg = lispToExprT bound tps' ann g' arg
    letToExpr _ _ _ _ (x:_) _ = error $ "Unparseable entry "++show x++" in let expression"
    
    withWitness :: (a -> SMTExpr a) -> SMTExpr a
    withWitness f = f undefined
    
    mkEq :: a -> a -> a
    mkEq = const id

quantToExpr :: (forall a. Args a => ArgAnnotation a -> (a -> SMTExpr Bool) -> SMTExpr Bool)
               -> (T.Text -> Maybe UntypedExpr)
               -> Map.Map TyCon DeclaredType -> (T.Text -> TypeRep) -> [L.Lisp] -> L.Lisp -> SMTExpr Bool
quantToExpr q bound tps' g' (L.List [L.Symbol var,tp]:rest) body
  = let decl = declForSMTType tp tps'
        getForall :: Typeable a => a -> SMTExpr a -> SMTExpr a
        getForall = const id
    in withDeclaredType 
       (\u ann ->
         q ann $ \subst -> quantToExpr q (\txt -> if txt==var
                                                  then Just $ UntypedExpr $ getForall u subst
                                                  else bound txt)                                   
                           tps' (\txt -> if txt==var
                                         then declaredTypeRep decl
                                         else g' txt) rest body) decl
quantToExpr q bound tps' g' [] body = lispToExprT bound tps' () g' body

instance (SMTValue a) => LiftArgs (SMTExpr a) where
  type Unpacked (SMTExpr a) = a
  liftArgs = Const
  unliftArgs = getValue
