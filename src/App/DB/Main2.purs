module App.DB.Main2 where
--
-- import Prelude
--
-- import App.IgoMsg (IgoMsg(..))
-- import App.Streaming (MapFn, ReduceFn, FlumeDb, mapFn, reduceFn)
-- import Control.Monad.Eff (Eff)
-- import Data.Argonaut (Json, fromObject, fromString)
-- import Data.Argonaut.Generic.Aeson (encodeJson)
-- import Data.Foreign (Foreign, toForeign)
-- import Data.StrMap (StrMap)
-- import Data.StrMap as M
-- import Data.Tuple (Tuple(..))
-- import Ssb.Config (SSB)
-- import Ssb.PullStream (PullStream)
--
--
-- plugin =
--   { init: init
--   , name: "ssbIgoDb"
--   , version: "0.1"
--   , manifest: {}
--   }
--
-- interface sbot = do
--   view <- flumeUse sbot "ssb-igo-index" flumeReducer
--   stream <- liveStream view
--   pure
--     [ SourceMethod "streamDb" \_ -> stream]
--
-- streamDb :: Sbot -> Eff (ssb :: SSB) PluginMethod
-- streamDb sbot = do
--   view <- flumeUse sbot "ssb-igo-index" flumeReducer
--   pure $ SourceMethod "streamDb"
--
-- newtype SsbPlugin = SsbPlugin
--   { interface :: Array PluginMethod
--   , name :: String
--   , version :: String
--   }
--
-- pluginJson :: SsbPlugin -> StrMap Foreign
-- pluginJson (SsbPlugin {interface, name, version}) =
--   M.fromFoldable
--     [ "init" := toForeign init
--     , "manifest" := toForeign manifest
--     , "name" := toForeign name
--     , "version" := toForeign version
--     ]
--
--   where
--     init :: Sbot -> StrMap Foreign
--     init sbot = M.fromFoldable $ interface <#> case _ of
--       SourceMethod name fn -> (name := (fn sbot))
--
--     manifest :: StrMap String
--     manifest = M.fromFoldable $ interface <#> case _ of
--       SourceMethod name _ -> (name := "source")
--
-- data PluginMethod
--   = SourceMethod String (Sbot -> Foreign)
--
-- infixr 4 Tuple as :=
--
-- manifest = M.fromFoldable
--   [ "streamDb" := "stream" ]
--
--
-- flumeReducer = mkFlumeReducer "0.1" reduceFn mapFn {}
--
-- foreign import data FlumeReducer :: Type
-- foreign import data FlumeView :: Type
-- foreign import data Sbot :: Type
-- foreign import mkFlumeReducer :: String -> ReduceFn -> MapFn -> FlumeDb -> FlumeReducer
-- foreign import flumeUse :: ∀ fx. Sbot -> String -> FlumeReducer -> Eff (ssb :: SSB | fx) FlumeView
-- foreign import liveStream :: ∀ fx. FlumeView -> Eff (ssb :: SSB | fx) PullStream