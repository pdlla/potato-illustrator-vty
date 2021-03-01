{-# LANGUAGE TemplateHaskell          #-}

module Reflex.Vty.Test.Monad.Host.TH (
  declareStuff
  , tv

  -- for testing
  , declareNetworkData
  , declareNetworkInstance
  , declareOutputs
) where

import Prelude (foldl)
import           Relude                   hiding (getFirst, Type)

import Data.Char (toLower)
import Language.Haskell.TH

import           Reflex
import           Reflex.Vty.Test.Monad.Host
import           Reflex.Host.Class (EventTrigger, newEventWithTriggerRef)
import           Control.Monad.Ref

tv :: Q Type
tv = varT $ mkName "t"
-- does this capture types in generated scope? Probably not???
--tv = do
--  Just r <- lookupTypeName "t"
--  varT r

declareNetworkData :: Name -> Q [Dec]
declareNetworkData name = do
  let
    k_m = InfixT StarT ''(->) StarT
  tv_t <- newName "t"
  tv_m <- newName "m"
  -- not sure if KindedTV is necessary
  return $ [DataD [] name [PlainTV tv_t, KindedTV tv_m k_m] Nothing [] []]

declareNetworkInstance :: Name -> [(String, Q Type)] -> [(String, Q Type)] -> Q Exp -> Q [Dec]
declareNetworkInstance name inputEventTypes outputTypes body = do
  let
    v_t = VarT $ mkName "t"
    v_m = VarT $ mkName "m"
    cxt1 = AppT (AppT (ConT $ mkName "MonadVtyApp") v_t) $ AppT (AppT (ConT $ mkName "TestGuestT") v_t) v_m
    cxt2 = AppT (AppT (ConT $ mkName "TestGuestConstraints") v_t) $ v_m
    v_potatoNetwork = AppT (AppT (ConT $ name) v_t) v_m
    --instance (MonadVtyApp t (TestGuestT t m), TestGuestConstraints t m) => ReflexVtyTestApp ([|$(VarT name)|] t m) t m where
    classinstance = AppT (AppT (AppT (ConT $ mkName "ReflexVtyTestApp") v_potatoNetwork) v_t) v_m
  -- same but using quasiquoters
  --cxt1 <- [t| $(conT $ mkName "MonadVtyApp") $(varT $ mkName "t") ($(conT $ mkName "TestGuestT") $(varT $ mkName "t") $(varT $ mkName "m")) |]

  outputs <- declareOutputs name outputTypes
  inputs <- declareInputs name inputEventTypes
  makeInputsFn <- declareMakeInputs name inputEventTypes
  bodyFn <- declareGetApp name body

  return $ [InstanceD Nothing [cxt1,cxt2] classinstance ((outputs:inputs) <> [makeInputsFn, bodyFn])]

normalBang :: Bang
normalBang = Bang NoSourceUnpackedness NoSourceStrictness

convertNameToPrefixedNameField :: Name -> String -> Name
convertNameToPrefixedNameField name suffix = r where
  prefix = case nameBase name of
    [] -> ""
    x:xs -> (toLower x):xs
  r = mkName $ "_" <> prefix <> "_" <> suffix

convertNameToPrefixedNameType :: Name -> String -> Name
convertNameToPrefixedNameType name suffix = r where
  r = mkName $ nameBase name <> "_" <> suffix

varNetwork :: Name -> Type
varNetwork name = r where
  v_t = VarT $ mkName "t"
  v_m = VarT $ mkName "m"
  r = AppT (AppT (ConT $ name) v_t) v_m

declareOutputs :: Name -> [(String, Q Type)] -> Q Dec
declareOutputs name outputTypes = do
  recs <- forM (fmap (\(x,q) -> fmap (x,) q) outputTypes) $ \nt -> do
    (n,t) <- nt
    let
      fname = convertNameToPrefixedNameField name ("Output_" <> n)
    return (fname, normalBang, t)
  let
    recname = convertNameToPrefixedNameType name "Output"
    cs = [RecC recname recs]
  return $ DataInstD [] Nothing (AppT (ConT $ mkName "VtyAppOutput") (varNetwork name)) Nothing cs []

mkvar :: String -> Q Type
mkvar = varT . mkName

declareInputs :: Name -> [(String, Q Type)] -> Q [Dec]
declareInputs name inputEventTypes = do
  recs <- forM (fmap (\(x,q) -> fmap (x,) q) inputEventTypes) $ \nt -> do
    (n, t) <- nt
    let
      infname = convertNameToPrefixedNameField name ("InputEvents_" <> n)
      trigfname = convertNameToPrefixedNameField name ("InputTriggerRefs_" <> n)
    int <- [t|Event $(tv) $(return t)|]
    trigt <- [t| Ref $(mkvar "m") (Maybe (EventTrigger $(tv) $(return t))) |]
    return ((infname, normalBang, int), (trigfname, normalBang, trigt))

  let
    (inrecs, trigrecs) = unzip recs
    incs = [RecC (convertNameToPrefixedNameType name "InputEvents") inrecs]
    trigcs = [RecC (convertNameToPrefixedNameType name "InputTriggerRefs") trigrecs]
    indi = DataInstD [] Nothing (AppT (ConT $ mkName "VtyAppInputEvents") (varNetwork name)) Nothing incs []
    trigdi = DataInstD [] Nothing (AppT (ConT $ mkName "VtyAppInputTriggerRefs") (varNetwork name)) Nothing trigcs []
  return [indi, trigdi]

declareMakeInputs :: Name -> [(String, Q Type)] -> Q Dec
declareMakeInputs name inputEventTypes = do
  varnames <- forM (fmap (\(x,q) -> fmap (x,) q) inputEventTypes) $ \nt -> do
    (n, t) <- nt
    evname <- newName "ev"
    trefname <- newName "ref"
    return (evname, trefname)
  refstmts <- forM varnames $ \(evname,trefname) -> do
    return $ BindS (TupP [VarP evname, VarP trefname]) $ VarE (mkName "newEventWithTriggerRef")
  let
    returnstmtsfst = foldl AppE (ConE $ convertNameToPrefixedNameType name "InputEvents") (fmap (VarE . fst) varnames)
    returnstmtssnd = foldl AppE (ConE $ convertNameToPrefixedNameType name "InputTriggerRefs") (fmap (VarE . snd) varnames)
  returnstmts <- [|return ($(return returnstmtsfst),$(return returnstmtssnd))|]
  let
    b = NormalB $ DoE (refstmts <> [NoBindS returnstmts])
    c = Clause [] b []
  return $ FunD (mkName "makeInputs") [c]


declareGetApp :: Name -> Q Exp -> Q Dec
declareGetApp name body' = do
  body <- body'
  let
    b = NormalB $ body
    c = Clause [VarP $ mkName "inputEvs"] b []
  return $ FunD (mkName "getApp") [c]



declareStuff :: String -> [(String, Q Type)] -> [(String, Q Type)] -> Q Exp -> Q [Dec]
declareStuff name' inputEventTypes outputTypes body = do
  let
    name = mkName name'
  declareNetworkData name
  declareNetworkInstance name inputEventTypes outputTypes body


--ReflexVtyTestApp (PotatoNetwork t m) t m

{-

data BasicNetworkTest1 t (m :: Type -> Type)

instance (MonadVtyApp t (TestGuestT t m), TestGuestConstraints t m) => ReflexVtyTestApp (BasicNetworkTest1 t m) t m where

  -- I just wanted to try using VtyAppInputEvents/VtyAppInputTriggerRefs
  -- it would have been a lot easier to use a vty event to trigger the popup
  data VtyAppInputTriggerRefs (BasicNetworkTest1 t m) = BasicNetworkTest1_InputTriggerRefs {
      _basicNetworkTest1_InputTriggerRefs_makePopup :: Ref m (Maybe (EventTrigger t ()))
    }
  data VtyAppInputEvents (BasicNetworkTest1 t m) = BasicNetworkTest1_InputEvents {
      _basicNetworkTest1_InputEvents_makePopup :: Event t ()
    }
  data VtyAppOutput (BasicNetworkTest1 t m) =
    BasicNetworkTest1_Output {
        _basicNetworkTest1_Output_cancelEv :: Event t ()
        , _basicNetworkTest1_Output_popupOutEv :: Event t Int
        , _basicNetworkTest1_Output_popupStateDyn :: Dynamic t Bool
      }
  getApp BasicNetworkTest1_InputEvents {..} = do
    let
      someWidget = fmap (const 123) <$> key V.KEnter
      someWidgetEv = fmap (const someWidget) _basicNetworkTest1_InputEvents_makePopup
    -- popup that closes when you press enter
    (popupEv, popupStateDyn) <- popupPaneSimple def someWidgetEv
    -- gotta make the popup look pretty :D
    fill '#'
    return $ BasicNetworkTest1_Output never popupEv popupStateDyn

-}
