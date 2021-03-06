module App.Flume where

import Prelude

import App.Common (messageTypeString)
import App.IgoMsg (AcceptMatchPayload, DeclineMatchFields, DeclineMatchPayload, IgoMove(Finalize, ToggleDead, Pass, PlayStone, Resign), IgoMsg(Kibitz, PlayMove, AcknowledgeDecline, DeclineMatch, AcceptMatch, WithdrawOffer, OfferMatch, ExpireRequest, RequestMatch), MsgKey, OfferMatchPayload, PlayMovePayload, RequestMatchPayload, StoneColor(Black, White), parseIgoMessage)
import App.Utils (upsert, (&))
import Control.Alt ((<|>))
import Data.Argonaut (Json, fromObject, jsonNull, toObject, toString)
import Data.Argonaut.Generic.Argonaut (decodeJson, encodeJson)
import Data.Array (filter, last, snoc)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Either (either, hush)
import Data.Function.Uncurried (Fn2)
import Data.Generic (class Generic, gEq, gShow)
import Data.Maybe (Maybe(Nothing, Just), maybe)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Record as Record
import Data.StrMap (StrMap, delete, fromFoldable, insert, lookup)
import Data.StrMap as M
import Data.Symbol (SProxy(..))
import Data.Traversable (sequence)
import Data.Tuple (Tuple(..))
import Debug.Trace (trace)
import Ssb.Types (UserKey, MessageKey)


type FlumeData =
  { offers :: StrMap IndexedOffer
  , declines :: StrMap IndexedDecline
  , requests :: StrMap IndexedRequest
  , matches :: StrMap IndexedMatch
  , moves :: StrMap IndexedMove
  , matchKibitzes :: StrMap (Array KibitzStep)
  }

data FlumeState
  = FlumeDb FlumeData
  | FlumeUnloaded
  | FlumeFailure String

initialDb :: FlumeData
initialDb =
  { offers: M.empty
  , declines: M.empty
  , requests: M.empty
  , matches: M.empty
  , moves: M.empty
  , matchKibitzes: M.empty
  }


-- TODO: make newtype
data IndexedOffer = IndexedOffer OfferMatchPayload {author :: UserKey, key :: MsgKey}
data IndexedDecline = IndexedDecline {userKey :: UserKey | DeclineMatchFields} {author :: UserKey, key :: MsgKey}
data IndexedRequest = IndexedRequest RequestMatchPayload {author :: UserKey, key :: MsgKey}
data IndexedMove = IndexedMove PlayMovePayload {rootAccept :: MsgKey} {author :: UserKey, key :: MsgKey}
newtype IndexedMatch = IndexedMatch
  { acceptPayload :: AcceptMatchPayload
  , offerPayload :: OfferMatchPayload
  , moves :: Array MoveStep
  , acceptMeta :: {author :: UserKey, key :: MsgKey}
  , offerMeta :: {author :: UserKey, key :: MsgKey}
  }
derive instance newtypeIndexedMatch :: Newtype IndexedMatch _
derive instance genericIndexedOffer :: Generic IndexedOffer
derive instance genericIndexedDecline :: Generic IndexedDecline
derive instance genericIndexedRequest :: Generic IndexedRequest
derive instance genericIndexedMatch :: Generic IndexedMatch
derive instance genericIndexedMove :: Generic IndexedMove

newtype MoveStep = MoveStep {move :: IgoMove, key :: MsgKey}
newtype KibitzStep = KibitzStep {text :: String, author :: UserKey}
derive instance newtypeMoveStep :: Newtype MoveStep _
derive instance genericMoveStep :: Generic MoveStep
derive instance genericKibitzStep :: Generic KibitzStep


instance showIndexedOffer :: Show IndexedOffer where show = gShow
instance showIndexedDecline :: Show IndexedDecline where show = gShow
instance showIndexedRequest :: Show IndexedRequest where show = gShow
instance showIndexedMatch :: Show IndexedMatch where show = gShow
instance showIndexedMove :: Show IndexedMove where show = gShow

instance eqIndexedOffer :: Eq IndexedOffer where eq = gEq
instance eqIndexedDecline :: Eq IndexedDecline where eq = gEq
instance eqIndexedRequest :: Eq IndexedRequest where eq = gEq
instance eqIndexedMatch :: Eq IndexedMatch where eq = gEq
instance eqIndexedMove :: Eq IndexedMove where eq = gEq


decodeFlumeDb :: Json -> Maybe FlumeData
decodeFlumeDb json = do
  o <- toObject json
  offers <- M.lookup "offers" o >>= toObject >>= (map (decodeJson >>> hush) >>> sequence)
  requests <- M.lookup "requests" o >>= toObject >>= (map (decodeJson >>> hush) >>> sequence)
  declines <- M.lookup "declines" o >>= toObject >>= (map (decodeJson >>> hush) >>> sequence)
  matches <- M.lookup "matches" o >>= toObject >>= (map (decodeJson >>> hush) >>> sequence)
  moves <- M.lookup "moves" o >>= toObject >>= (map (decodeJson >>> hush) >>> sequence)
  matchKibitzes <- M.lookup "matchKibitzes" o >>= toObject >>= (map (decodeJson >>> hush) >>> sequence)
  pure $ { offers, requests, declines, matches, moves, matchKibitzes }

maybeToFlumeState :: String -> Maybe FlumeData -> FlumeState
maybeToFlumeState err = maybe (FlumeFailure err) FlumeDb

encodeFlumeDb :: FlumeData -> Json
encodeFlumeDb db =
  fromObject $ fromFoldable
    [ "offers" & (fromObject $ map encodeJson db.offers)
    , "requests" & (fromObject $ map encodeJson db.requests)
    , "declines" & (fromObject $ map encodeJson db.declines)
    , "matches" & (fromObject $ map encodeJson db.matches)
    , "moves" & (fromObject $ map encodeJson db.moves)
    , "matchKibitzes" & (fromObject $ map encodeJson db.matchKibitzes)
    ]

type ReduceFn = FlumeData -> Json -> FlumeData
type ReduceFnImpl = Fn2 Json Json Json
type MapFn = Json -> Json

data MessageType
  = ValidPayload Json
  | PrivateMessage
  | InvalidMessage


assignColors :: IndexedMatch -> {black :: UserKey, white :: UserKey}
assignColors (IndexedMatch {offerPayload, offerMeta}) = assignColors' offerPayload offerMeta

assignColors' :: ∀ a. OfferMatchPayload -> { author :: UserKey | a} -> {black :: UserKey, white :: UserKey}
assignColors' {myColor, opponentKey} {author} =
  case myColor of
    Black -> { black: author, white: opponentKey}
    White -> { white: author, black: opponentKey}

myColor :: IndexedMatch -> UserKey -> Maybe StoneColor
myColor match whoami =
  if whoami == black
  then Just Black
  else if whoami == white
  then Just White
  else Nothing
  where {black, white} = assignColors match

addUserKey :: ∀ a. String -> DeclineMatchPayload -> {userKey :: String | DeclineMatchFields}
addUserKey = Record.insert (SProxy :: SProxy "userKey")


reduceFn :: ReduceFn
reduceFn (db) json =
  reduceRight $ case _ of

    Tuple (RequestMatch payload) {key, author} ->
      db { requests = insert key (IndexedRequest payload {key, author}) db.requests }

    Tuple (ExpireRequest targetKey) {author} ->
      lookup targetKey db.requests
        # maybe db \(IndexedRequest _ meta) ->
          if author == meta.author
            then db { requests = delete targetKey db.requests }
            else db

    Tuple (OfferMatch payload) {key, author} ->
      db { offers = insert key (IndexedOffer payload {key, author}) db.offers }

    Tuple (WithdrawOffer targetKey) {author} ->
      lookup targetKey db.offers
        # maybe db \(IndexedOffer _ meta) ->
          if author == meta.author
            then db { offers = delete targetKey db.offers }
            else db

    Tuple (AcceptMatch acceptPayload@{offerKey}) acceptMeta@{key} ->
      lookup offerKey db.offers
        # maybe db \(IndexedOffer offerPayload@{opponentKey} offerMeta) ->
          if acceptMeta.author == opponentKey
            then
              let match = IndexedMatch
                            { acceptPayload
                            , offerPayload
                            , moves: []
                            , acceptMeta: {author: acceptMeta.author, key: acceptMeta.key}
                            , offerMeta: {author: offerMeta.author, key: offerMeta.key}
                            }
              in db { offers = delete offerKey db.offers
                    , matches = insert key match db.matches
                    }
            else db

    Tuple (DeclineMatch payload@{offerKey}) {key, author} ->
      lookup offerKey db.offers
        # maybe db \(IndexedOffer {opponentKey} meta) ->
          if author == opponentKey
            then
              let payload' = addUserKey meta.author payload
              in db { offers = delete offerKey db.offers
                    , declines = insert key (IndexedDecline payload' {key, author}) db.declines
                    }
            else db

    Tuple (AcknowledgeDecline targetKey) {author} ->
      lookup targetKey db.declines
        # maybe db \(IndexedDecline {userKey} meta) ->
          if author == userKey
            then db { declines = delete targetKey db.declines }
            else db

    Tuple (PlayMove payload@{move, lastMove}) {author, key} ->
      case rootMatch lastMove of
        Nothing -> trace "invalid message chain" $ const db
        Just match@(IndexedMatch {acceptMeta}) ->
          let rootAccept = acceptMeta.key
              moveError = validateMove match payload author
          in case moveError of
            Nothing ->
              let
                newMove = IndexedMove payload {rootAccept} {key, author}
                moveStep = MoveStep {move, key}
                newMatch = match # unwrap >>> (\m -> m { moves = snoc m.moves moveStep }) >>> wrap
              in db { moves   = M.insert key newMove db.moves
                    , matches = M.insert rootAccept newMatch db.matches }
            Just err ->
              trace ("move validation error: " <> err) $ const db

    Tuple (Kibitz payload@{move, text}) {author} ->
      case rootMatch move of
        Nothing -> trace "invalid message chain" $ const db
        Just match@(IndexedMatch {acceptMeta}) ->
          let
            newKibitz = KibitzStep {text, author}
            append arr = Just $ snoc arr newKibitz
          in db { matchKibitzes = upsert append acceptMeta.key [] db.matchKibitzes }

  where

    msg = parseIgoMessage json # lmap \err -> trace ("bad message: " <> err <> ". json = " <> show json)
    reduceRight f = either (const db) (f <<< \m -> Tuple m.content m) msg

    rootMatch lastMove =
      case M.lookup lastMove db.moves, M.lookup lastMove db.matches of
        Nothing, Just match ->
          Just match
        Just (IndexedMove _ {rootAccept} _), Nothing ->
          M.lookup rootAccept db.matches
        _, _ -> Nothing  -- NB: also handles case of Just, Just, which is absurd

    validateMove
      match@(IndexedMatch {offerPayload, offerMeta, moves})
      payload@{move, lastMove}
      author = validateLastMove <|> validateFinalization <|>
        case move of
          PlayStone _ -> validatePlayer
          Pass -> validatePlayer
          Resign -> Nothing
          ToggleDead _ -> validateEndMove
          Finalize ->
            case _.move <<< unwrap <$> last moves of
              Just Finalize -> validatePlayer <|> validateEndMove
              Just _ -> validateEndMove
              Nothing -> validateEndMove
        where
          validateLastMove =
            if lastKey == lastMove
            then Nothing
            else Just $ "move is not in response to last valid move! "
                     <> author <> " || "
                     <> lastKey
            where lastKey = lastMoveKey match

          validatePlayer =
            if author == nextMover db match
            then Nothing
            else Just $ "not your turn to move! " <> author

          validateEndMove =
            if isMatchEnd match
            then Nothing
            else Just $ "can only play move at end of game: " <> show move

          validateFinalization =
            if isMatchFinalized match
            then Just $ "match is finalized, no more moves possible!"
            else Nothing


    getPlayers :: IndexedMatch -> {black :: UserKey, white :: UserKey}
    getPlayers (IndexedMatch {offerPayload, offerMeta}) =
      assignColors' offerPayload offerMeta

matchKey :: IndexedMatch -> MessageKey
matchKey (IndexedMatch {acceptMeta}) = acceptMeta.key

lastMoveKey :: IndexedMatch -> MessageKey
lastMoveKey (IndexedMatch {moves, acceptMeta}) =
  maybe acceptMeta.key (_.key <<< unwrap) (last moves)

nextMover :: FlumeData -> IndexedMatch -> UserKey
nextMover db match@(IndexedMatch {offerPayload, offerMeta}) =
  method2
  where
    {author} = offerMeta
    {terms, myColor, opponentKey} = offerPayload
    {handicap} = terms
    firstMover = if (myColor == Black) == (handicap == 0)
                    then author
                    else opponentKey
    method2 = case M.lookup (lastMoveKey match) db.moves of
                Just (IndexedMove _ _ lastMeta) -> if author == lastMeta.author then opponentKey else author
                Nothing -> firstMover

moveNumber :: IndexedMatch -> Int
moveNumber match@(IndexedMatch {moves}) =
  Array.length $ filter gameMove moves
  where
    gameMove (MoveStep {move}) = case move of
      PlayStone _ -> true
      _ -> false

isMatchEnd :: IndexedMatch -> Boolean
isMatchEnd match@(IndexedMatch {moves}) =
  let lastTwo = _.move <<< unwrap <$> Array.drop (Array.length moves - 2) moves
  in case lastTwo of
    [] -> false
    [_] -> false
    [Pass, Pass] -> true
    [_, ToggleDead _] -> true
    [_, Finalize] -> true
    _ -> false

isMatchFinalized :: IndexedMatch -> Boolean
isMatchFinalized match@(IndexedMatch {moves}) =
  let lastTwo = _.move <<< unwrap <$> Array.drop (Array.length moves - 2) moves
  in case lastTwo of
    [Finalize, Finalize] -> true
    _ -> false

mapFn :: MapFn
mapFn json = if isValidMessage json then json else jsonNull

isValidMessage :: Json -> Boolean
isValidMessage json = maybe false ((==) messageTypeString) (messageType json)

messageType :: Json -> Maybe String
messageType json = toObject json
  >>= lookup "value" >>= toObject
  >>= lookup "content" >>= toObject
  >>= lookup "type" >>= toString
