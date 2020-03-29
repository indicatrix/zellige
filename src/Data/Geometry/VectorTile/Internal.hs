{-# LANGUAGE DataKinds              #-}
{-# LANGUAGE DuplicateRecordFields  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TypeFamilyDependencies #-}

-- |
-- Module    : Geography.VectorTile.Internal
-- Copyright : (c) Colin Woodbury 2016 - 2018
-- License   : BSD3
-- Maintainer: Colin Woodbury <colingw@gmail.com>
--
-- Raw Vector Tile data is stored as binary protobuf data.
-- This module reads and writes raw protobuf ByteStrings between a data type
-- which closely matches the current Mapbox vector tile spec defined here:
-- https://github.com/mapbox/vector-tile-spec/blob/master/2.1/vector_tile.proto
--
-- As this raw version of the data is hard to work with, in practice we convert
-- to a more canonical Haskell type for further processing.
-- See "Geography.VectorTile" for the user-friendly version.

module Data.Geometry.VectorTile.Internal
  ( -- * Types
    -- ** Protobuf Conversion
    Protobuf
  , Protobuffable(..)
  , ProtobufGeom(..)
    -- ** Decoded Middle-Types
  , Tile.Tile(Tile, layers)
  , Layer.Layer(Layer, version, name, features, keys, values, extent)
  , Feature.Feature(..)
  , Value.Value(..)
  , GeomVec
  , GeomType.GeomType(..)
    -- * Commands
  , Command(..)
  , commands
  , uncommands
   -- * Z-Encoding
  , zig
  , unzig
    -- * Protobuf Conversions
    -- | Due to Protobuf Layers and Features having their data coupled,
    -- we can't define a `Protobuffable` instance for `VT.Feature`s,
    -- and instead must use the two functions below.
  , feats
  , unfeats
  ) where

import           Control.Applicative
                                                                                       ((<|>))
import           Control.Monad
                                                                                       (foldM,
                                                                                       void,
                                                                                       (>=>))
import           Control.Monad.Except
import           Control.Monad.State.Strict
import           Data.Bits
import qualified Data.ByteString.Lazy                                                 as BL
import qualified Data.Foldable                                                        as Foldable
import qualified Data.Geometry.VectorTile.Geometry                                    as G
import qualified Data.Geometry.VectorTile.Protobuf.Internal.Vector_tile.Tile          as Tile
import qualified Data.Geometry.VectorTile.Protobuf.Internal.Vector_tile.Tile.Feature  as Feature
import qualified Data.Geometry.VectorTile.Protobuf.Internal.Vector_tile.Tile.GeomType as GeomType
import qualified Data.Geometry.VectorTile.Protobuf.Internal.Vector_tile.Tile.Layer    as Layer
import qualified Data.Geometry.VectorTile.Protobuf.Internal.Vector_tile.Tile.Value    as Value
import qualified Data.Geometry.VectorTile.Types                                       as VT
import           Data.Geometry.VectorTile.Util
import qualified Data.HashMap.Strict                                                  as M
import qualified Data.HashSet                                                         as HS
import           Data.Int
import           Data.List
                                                                                       (unfoldr)
import           Data.Maybe
                                                                                       (fromJust)
import qualified Data.Maybe                                                           as Maybe
import qualified Data.Sequence                                                        as Seq
import           Data.Text
                                                                                       (Text,
                                                                                       pack)
import           Data.Word
import           Text.Printf
import           Text.ProtocolBuffers.Basic
                                                                                       (Utf8 (..),
                                                                                       defaultValue,
                                                                                       utf8)

---

-- | A family of data types which can associated with concrete underlying
-- Protobuf types.
type family Protobuf a = pb | pb -> a
type instance Protobuf VT.VectorTile = Tile.Tile
type instance Protobuf VT.Layer = Layer.Layer
type instance Protobuf VT.Val = Value.Value

type family GeomVec g = v | v -> g
type instance GeomVec G.Point      = Seq.Seq G.Point
type instance GeomVec G.LineString = Seq.Seq G.LineString
type instance GeomVec G.Polygon    = Seq.Seq G.Polygon

-- | A type which can be converted to and from an underlying Protobuf type,
-- according to the `Protobuf` type family.
class Protobuffable a where
  fromProtobuf :: Protobuf a -> Either Text a
  toProtobuf   :: a -> Protobuf a

instance Protobuffable VT.VectorTile where
  fromProtobuf raw = do
    ls <- traverse fromProtobuf . Foldable.toList $ Tile.layers raw
    pure . VT.VectorTile . M.fromList $ map (\l -> (VT._name l, l)) ls

  toProtobuf vt = Tile.Tile { Tile.layers    = Seq.fromList . map toProtobuf . M.elems $ VT._layers vt
                            , Tile.ext'field = defaultValue }

instance Protobuffable VT.Layer where
  fromProtobuf l = do
    Feats ps ls polys <- feats (utf8 <$> Layer.keys l) (Layer.values l) $ Layer.features l
    pure VT.Layer { VT._version     = fromIntegral $ Layer.version l
                  , VT._name        = utf8 $ Layer.name l
                  , VT._points      = ps
                  , VT._linestrings = ls
                  , VT._polygons    = polys
                  , VT._extent      = maybe 4096 fromIntegral (Layer.extent l) }

  toProtobuf l = Layer.Layer { Layer.version   = fromIntegral $ VT._version l
                             , Layer.name      = Utf8 $ VT._name l
                             , Layer.features  = fs  -- Conversion bottleneck?
                             , Layer.keys      = Seq.fromList $ map Utf8 ks
                             , Layer.values    = Seq.fromList $ map toProtobuf vs
                             , Layer.extent    = Just . fromIntegral $ VT._extent l
                             , Layer.ext'field = defaultValue }
    where (ks,vs) = totalMeta (VT._points l) (VT._linestrings l) (VT._polygons l)
          (km,vm) = (M.fromList $ zip ks [0..], M.fromList $ zip vs [0..])
          fs = Foldable.fold [ fmap (unfeats km vm GeomType.POINT) (VT._points l)
                    , fmap (unfeats km vm GeomType.LINESTRING) (VT._linestrings l)
                    , fmap (unfeats km vm GeomType.POLYGON) (VT._polygons l) ]

instance Protobuffable VT.Val where
  fromProtobuf v = maybe (Left "Value decode: No legal Value type offered") Right $
        fmap (VT.St . utf8) (Value.string_value v)
    <|> fmap VT.Fl  (Value.float_value v)
    <|> fmap VT.Do  (Value.double_value v)
    <|> fmap VT.I64 (Value.int_value v)
    <|> fmap VT.W64 (Value.uint_value v)
    <|> fmap VT.S64 (Value.sint_value v)
    <|> fmap VT.B   (Value.bool_value v)

  toProtobuf (VT.St v)  = defaultValue { Value.string_value = Just $ Utf8 v }
  toProtobuf (VT.Fl v)  = defaultValue { Value.float_value  = Just v }
  toProtobuf (VT.Do v)  = defaultValue { Value.double_value = Just v }
  toProtobuf (VT.I64 v) = defaultValue { Value.int_value    = Just v }
  toProtobuf (VT.W64 v) = defaultValue { Value.uint_value   = Just v }
  toProtobuf (VT.S64 v) = defaultValue { Value.sint_value   = Just v }
  toProtobuf (VT.B v)   = defaultValue { Value.bool_value   = Just v }

-- | Any classical type considered a GIS "geometry". These must be able
-- to convert between an encodable list of `Command`s.
class ProtobufGeom g where
  fromCommands :: [Command] -> Either Text (GeomVec g)
  toCommands   :: GeomVec g -> [Command]

-- | A valid `RawFeature` of points must contain a single `MoveTo` command
-- with a count greater than 0.
instance ProtobufGeom G.Point where
  fromCommands [ MoveTo ps ] = Right $ expand (G.Point 0 0) ps
  fromCommands (c : _)       = Left . pack $ printf "Invalid command found in Point feature: %s" (show c)
  fromCommands []            = Left "No points given!"

  -- | A multipoint geometry must reduce to a single `MoveTo` command.
  toCommands ps = [ MoveTo $ evalState (mapM collapse ps) (G.Point 0 0) ]

-- | A valid `RawFeature` of linestrings must contain pairs of:
--
-- A `MoveTo` with a count of 1, followed by one `LineTo` command with
-- a count greater than 0.
instance ProtobufGeom G.LineString where
  fromCommands cs = evalStateT (unfoldM f cs) (G.Point 0 0)
    where f :: [Command] -> StateT G.Point (Either Text) (Maybe (G.LineString, [Command]))
          f (MoveTo (headP Seq.:<| _) : LineTo ps : rs) = do
            curr <- get
            let ls = G.LineString . expand curr $ (Seq.<|) headP ps
            case Seq.viewr (G.lsPoints ls) of
              Seq.EmptyR         -> put curr
              _ Seq.:> lastLsPts -> put lastLsPts
            pure $ Just (ls, rs)
          f [] = pure Nothing
          f _  = throwError "LineString decode: Invalid command sequence given."

  toCommands ls = Foldable.fold $ evalState (traverse f ls) (G.Point 0 0)
    where f (G.LineString ps) = do
            l <- mapM collapse ps
            pure $ case Seq.viewl l of
              Seq.EmptyL         -> []
              headL Seq.:< tailL -> [ MoveTo (Seq.singleton headL), LineTo tailL ]

-- | A valid `RawFeature` of polygons must contain at least one sequence of:
--
-- An Exterior Ring, followed by 0 or more Interior Rings.
--
-- Any Ring must have a `MoveTo` with a count of 1, a single `LineTo`
-- with a count of at least 2, and a single `ClosePath` command.
--
-- Performs no sanity checks for malformed Interior Rings.
instance ProtobufGeom G.Polygon where
  fromCommands cs = do
    polys <- evalStateT (unfoldM f cs) (G.Point 0 0)
    pure $ Seq.unfoldr g polys
    where f :: [Command] -> StateT G.Point (Either Text) (Maybe (G.Polygon, [Command]))
          f (MoveTo p : LineTo ps : ClosePath : rs) = do
            curr <- get
            case Seq.viewl p of
              Seq.EmptyL -> do
                put curr
                pure Nothing
              headP Seq.:< _ -> do
                let ps' = expand curr $ (Seq.<|) headP ps
                case Seq.viewr ps' of
                  Seq.EmptyR       -> put curr
                  _ Seq.:> lastPs' -> put lastPs'
                pure $ case Seq.viewl ps' of
                  Seq.EmptyL       -> Nothing
                  headPs' Seq.:< _ -> Just (G.Polygon ((Seq.|>) ps' headPs') mempty, rs)

          f [] = pure Nothing
          f _  = throwError . pack $ printf "Polygon decode: Invalid command sequence given: %s" (show cs)

          g :: Seq.Seq G.Polygon -> Maybe (G.Polygon, Seq.Seq G.Polygon)
          g v@(h Seq.:<| t)
            | Seq.null v  = Nothing
            | otherwise = Just (p, v')
            where
              p = h { G.inner = is }
              (is,v') = Seq.breakl (Maybe.maybe False (>0) . G.area) t
          g _ = Nothing

  toCommands ps = Foldable.fold $ evalState (traverse f ps) (G.Point 0 0)
    where f :: G.Polygon -> State G.Point [Command]
          f (G.Polygon (p Seq.:|> _) i) = do   -- Exclude the final point.
            x <- mapM collapse p
            case x of
              (h Seq.:<| t) -> do
                let cs = [ MoveTo (Seq.singleton h), LineTo t, ClosePath ]
                Foldable.fold . (cs :) <$> traverse f (Foldable.toList i)
              _ -> pure []
          f _ = pure []

-- | The possible commands, and the values they hold.
data Command = MoveTo (Seq.Seq G.Point)
             | LineTo (Seq.Seq G.Point)
             | ClosePath deriving (Eq,Show)

-- | Z-encode a 64-bit Int.
zig :: Int -> Word32
zig n = fromIntegral $ shift n 1 `xor` shift n (-63)
{-# INLINE zig #-}

-- | Decode a Z-encoded Word32 into a 64-bit Int.
unzig :: Word32 -> Int
unzig n = fromIntegral (fromIntegral unzigged :: Int32)
  where unzigged = shift n (-1) `xor` negate (n .&. 1)
{-# INLINE unzig #-}

-- | Divide a "Command Integer" into its @(Command,Count)@.
-- Throws if illegal values are given.
unsafeParseCmd :: Word32 -> Pair
unsafeParseCmd n = case cmd of
  1 -> Pair 1 (fromIntegral count)
  2 -> Pair 2 (fromIntegral count)
  7 | count == 1 -> Pair 7 1
    | otherwise  -> error $ "ClosePath was given a parameter count: " <> show count
  m -> error $ printf "Invalid command integer %d found in: %X" m n
  where cmd = n .&. 7
        count = shift n (-3)

-- | Recombine a Command ID and parameter count into a Command Integer.
unparseCmd :: Pair -> Word32
unparseCmd (Pair cmd count) = fromIntegral $ (cmd .&. 7) .|. shift count 3
{-# INLINE unparseCmd #-}

-- | Attempt to parse a list of Command/Parameter integers, as defined here:
--
-- https://github.com/mapbox/vector-tile-spec/tree/master/2.1#43-geometry-encoding
commands :: [Word32] -> [Command]
commands = unfoldr go
  where go [] = Nothing
        go (n : ns) = case unsafeParseCmd n of
          Pair 1 count ->
            let (ls, rs) = splitAt (count * 2) ns
                mts = MoveTo $ pairsWith unzig ls
            in Just (mts, rs)
          Pair 2 count ->
            let (ls, rs) = splitAt (count * 2) ns
                mts = LineTo $ pairsWith unzig ls
            in Just (mts, rs)
          Pair 7 _ -> Just (ClosePath, ns)
          _ -> error "Sentinel: You should never see this."

-- | Convert a list of parsed `Command`s back into their original Command
-- and Z-encoded Parameter integer forms.
uncommands :: [Command] -> Seq.Seq Word32
uncommands = Seq.fromList >=> f
  where f (MoveTo ps) = unparseCmd (Pair 1 (Seq.length ps)) Seq.<| params ps
        f (LineTo ls) = unparseCmd (Pair 2 (Seq.length ls)) Seq.<| params ls
        f ClosePath   = Seq.singleton $ unparseCmd (Pair 7 1)  -- ClosePath, Count 1.

{- FROM PROTOBUF -}

-- | Convert a list of `RawFeature`s of parsed protobuf data into `V.Vector`s
-- of each of the three legal `ProtobufGeom` types.
--
-- The long type signature is due to two things:
--
-- 1. `Feature`s are polymorphic at the high level, but not at the parsed
-- protobuf mid-level. In a @[RawFeature]@, there are features of points,
-- linestrings, and polygons all mixed together.
--
-- 2. `RawLayer`s and `RawFeature`s
-- are strongly coupled at the protobuf level. In order to achieve higher
-- compression ratios, `RawLayer`s contain all metadata in key/value lists
-- to be shared across their `RawFeature`s, while those `RawFeature`s store only
-- indices into those lists. As a result, this function needs to be passed
-- those key/value lists from the parent `RawLayer`, and a more isomorphic:
--
-- > feature :: ProtobufGeom g => RawFeature -> Either Text (Feature g)
--
-- is not possible.
feats :: Seq.Seq BL.ByteString -> Seq.Seq Value.Value -> Seq.Seq Feature.Feature -> Either Text Feats
feats _ _ Seq.Empty = Left "VectorTile.features: `[RawFeature]` empty"
feats keys vals fs = Foldable.foldlM g (Feats mempty mempty mempty) fs
  where f :: ProtobufGeom g => Feature.Feature -> Either Text (VT.Feature (GeomVec g))
        f x = VT.Feature
          <$> pure (maybe 0 fromIntegral $ Feature.id x)
          <*> getMeta keys vals (Feature.tags x)
          <*> (fromCommands . commands . Foldable.toList $ Feature.geometry x)

        g feets@(Feats ps ls po) fe = case Feature.type' fe of
          Just GeomType.POINT      -> (\fe' -> feets { featPoints = ps Seq.|> fe' }) <$> f fe
          Just GeomType.LINESTRING -> (\fe' -> feets { featLines  = ls Seq.|> fe' }) <$> f fe
          Just GeomType.POLYGON    -> (\fe' -> feets { featPolys  = po Seq.|> fe' }) <$> f fe
          _ -> Left "Geometry type of UNKNOWN given."

data Feats = Feats { featPoints :: !(Seq.Seq (VT.Feature (GeomVec G.Point)))
                   , featLines  :: !(Seq.Seq (VT.Feature (GeomVec G.LineString)))
                   , featPolys  :: !(Seq.Seq (VT.Feature (GeomVec G.Polygon))) }

getMeta :: Seq.Seq BL.ByteString -> Seq.Seq Value.Value -> Seq.Seq Word32 -> Either Text (M.HashMap BL.ByteString VT.Val)
getMeta keys vals tags = do
  let addKeys acc (G.Point k v) = (\v' -> M.insert (keys `Seq.index` k) v' acc) <$> fromProtobuf (vals `Seq.index` v)
  kv <- safePairsWith fromIntegral tags
  foldM addKeys M.empty kv

{- TO PROTOBUF -}

totalMeta :: Seq.Seq (VT.Feature (GeomVec G.Point))
          -> Seq.Seq (VT.Feature (GeomVec G.LineString))
          -> Seq.Seq (VT.Feature (GeomVec G.Polygon))
          -> ([BL.ByteString], [VT.Val])
totalMeta ps ls polys = (keys, vals)
  where keys = HS.toList $ f ps <> f ls <> f polys
        vals = HS.toList $ g ps <> g ls <> g polys
        f = foldMap (HS.fromMap . void . VT._metadata)
        g = foldMap (HS.fromList . M.elems . VT._metadata)

-- | Encode a high-level `Feature` back into its mid-level `RawFeature` form.
unfeats :: ProtobufGeom g
        => M.HashMap BL.ByteString Int
        -> M.HashMap VT.Val Int
        -> GeomType.GeomType
        -> VT.Feature (GeomVec g)
        -> Feature.Feature
unfeats keys vals gt fe = Feature.Feature
                            { Feature.id       = Just . fromIntegral $ VT._featureId fe
                            , Feature.tags     = Seq.fromList $ tags fe
                            , Feature.type'    = Just gt
                            , Feature.geometry = uncommands . toCommands $ VT._geometries fe }
  where tags = unpairs . map f . M.toList . VT._metadata
        f (k,v) = (fromIntegral . fromJust $ M.lookup k keys, fromIntegral . fromJust $ M.lookup v vals)

{- UTIL -}

-- | Transform a `Seq` of `Point`s into one of Z-encoded Parameter ints.
params :: Seq.Seq G.Point -> Seq.Seq Word32
params = Foldable.foldl' (\acc (G.Point a b) -> acc Seq.|> zig a Seq.|> zig b) Seq.Empty

-- | Expand a pair of diffs from some reference point into that of a `Point` value.
expand :: G.Point -> Seq.Seq G.Point -> Seq.Seq G.Point
expand curr s = Seq.drop 1 $ Seq.scanl (\(G.Point x y) (G.Point dx dy) -> G.Point (x + dx) (y + dy)) curr s

-- | Collapse a given `Point` into a pair of diffs, relative to
-- the previous point in the sequence. The reference point is moved
-- to the `Point` given.
collapse :: G.Point -> State G.Point G.Point
collapse p = do
  curr <- get
  let diff = G.Point (G.x p - G.x curr) (G.y p - G.y curr)
  put p
  pure diff

unfoldM :: Monad m => (s -> m (Maybe (a, s))) -> s -> m (Seq.Seq a)
unfoldM f s = do
    mres <- f s
    case mres of
        Nothing      -> pure Seq.empty
        Just (a, s') -> liftM2 (Seq.<|) (return a) (unfoldM f s')

