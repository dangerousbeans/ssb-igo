module App.UI.View.Dashboard where

import Prelude

import App.IgoMsg (IgoMsg(..), demoOfferPayload)
import App.Streaming (encodeFlumeDb)
import App.UI.Action (Action(..))
import App.UI.Model (EzModel, FlumeState(..), IndexedOffer(..), IndexedRequest(..), Model, ezify)
import Data.Array (filter, intercalate, singleton, zip)
import Data.Array.NonEmpty (replicate)
import Data.Foldable (find)
import Data.Maybe (Maybe(..))
import Data.StrMap (toUnfoldable)
import Data.StrMap as M
import Data.Tuple (Tuple(..))
import Global.Unsafe (unsafeStringify)
import Spork.Html (classes)
import Spork.Html as H
import Spork.Html.Elements.Keyed as K

class' = classes <<< singleton

dashboard :: EzModel -> H.Html Action
dashboard ez@{db, whoami} =
  H.div []
    [ H.section []
      [ H.h1 [] [H.text "requests"]
      , myRequest ez
      , H.h2 [] [H.text "offers"]
      , H.table []
        [ H.thead []
          [ H.th [] [H.text "From"]
          , H.th [] [H.text "Size"]
          ]
        , H.tbody [] (map offerRow offers)
        ]
      ]
    ]
  where
    offers :: Array IndexedOffer
    offers = M.values db.offers
      # filter \(IndexedOffer {opponentKey} _) -> opponentKey == whoami
--
-- table :: Array String -> Array String -> Array (H.Html Action) -> H.Html Action
-- table classNames headers rows =
--   H.table []
--     [ H.thead []
--       headElement
--   where
--     headElements = zip headers classNames # map \(title & className) ->
--       H.th [classes [className]] [H.text title]
--

myRequest :: EzModel -> H.Html Action
myRequest {db, whoami} =
  case r of
    Just request@(IndexedRequest {terms} {key}) ->
      requestLine request
    Nothing ->
      H.text "make a request?"
  where
    r = (M.values db.requests) # find \(IndexedRequest d {author}) ->
      author == whoami

requestLine :: IndexedRequest -> H.Html Action
requestLine (IndexedRequest {terms} _) =
  H.li [] [H.text $ show terms.size]

offerRow :: IndexedOffer -> H.Html Action
offerRow (IndexedOffer {terms, myColor} {author, key}) =
  H.tr []
    [ H.td [] [H.text author]
    , H.td [] [H.text size]
    ]
  where
    -- e.g. 19x19
    size = intercalate "x" $ replicate 2 $ show terms.size