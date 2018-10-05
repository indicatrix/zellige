{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards  #-}

module Data.Geometry.GeoJsonToMvt where

import qualified Control.Foldl                                                    as Foldl
import qualified Control.Monad.ST                                                 as MonadST
import qualified Data.Aeson                                                       as Aeson
import qualified Data.Aeson.Types                                                 as AesonTypes
import qualified Data.ByteString                                                  as ByteString
import qualified Data.ByteString.Lazy                                             as ByteStringLazy
import qualified Data.Foldable                                                    as Foldable
import qualified Data.Geospatial                                                  as Geospatial
import qualified Data.Hashable                                                    as Hashable
import qualified Data.HashMap.Strict                                              as HashMapStrict
import qualified Data.LinearRing                                                  as LinearRing
import qualified Data.LineString                                                  as LineString
import qualified Data.List                                                        as List
import           Data.Monoid
import qualified Data.SeqHelper                                                   as SeqHelper
import qualified Data.Sequence                                                    as Sequence
import qualified Data.STRef                                                       as STRef
import qualified Geography.VectorTile                                             as VectorTile
import qualified Geography.VectorTile.Internal                                    as VectorTileInternal
import qualified Geography.VectorTile.Protobuf.Internal.Vector_tile.Tile          as Tile
import qualified Geography.VectorTile.Protobuf.Internal.Vector_tile.Tile.Feature  as Feature
import qualified Geography.VectorTile.Protobuf.Internal.Vector_tile.Tile.GeomType as GeomType
import qualified Geography.VectorTile.Protobuf.Internal.Vector_tile.Tile.Layer    as Layer
import           Prelude                                                          hiding
                                                                                   (Left,
                                                                                   Right)
import qualified Text.ProtocolBuffers.Basic                                       as ProtocolBuffersBasic
import qualified Text.ProtocolBuffers.WireMessage                                 as WireMessage

import qualified Data.Geometry.Types.Config                                       as TypesConfig
import qualified Data.Geometry.Types.GeoJsonFeatures                              as TypesGeoJsonFeatures
import qualified Data.Geometry.Types.MvtFeatures                                  as TypesMvtFeatures

-- Lib

geoJsonFeaturesToMvtFeatures :: TypesGeoJsonFeatures.MvtFeatures -> Sequence.Seq (Geospatial.GeoFeature Aeson.Value) -> MonadST.ST s TypesGeoJsonFeatures.MvtFeatures
geoJsonFeaturesToMvtFeatures layer features = do
  ops <- STRef.newSTRef 0
  Foldable.foldMap (convertFeature layer ops) features

-- Feature

convertFeature :: TypesGeoJsonFeatures.MvtFeatures -> STRef.STRef s Word -> Geospatial.GeoFeature Aeson.Value -> MonadST.ST s TypesGeoJsonFeatures.MvtFeatures
convertFeature layer ops (Geospatial.GeoFeature _ geom props mfid) = do
  fid <- convertId mfid ops
  pure $ convertGeometry layer fid props geom

-- Geometry

convertGeometry :: TypesGeoJsonFeatures.MvtFeatures -> Word -> Aeson.Value -> Geospatial.GeospatialGeometry -> TypesGeoJsonFeatures.MvtFeatures
convertGeometry layer@TypesGeoJsonFeatures.MvtFeatures{..} fid props geom =
  case geom of
    Geospatial.NoGeometry     -> mempty
    Geospatial.Point g        -> layer { TypesGeoJsonFeatures.mvtPoints   = TypesMvtFeatures.mkPoint fid props (TypesGeoJsonFeatures.convertPoint g) mvtPoints }
    Geospatial.MultiPoint g   -> layer { TypesGeoJsonFeatures.mvtPoints   = TypesMvtFeatures.mkPoint fid props (TypesGeoJsonFeatures.convertMultiPoint g) mvtPoints }
    Geospatial.Line g         -> layer { TypesGeoJsonFeatures.mvtLines    = TypesMvtFeatures.mkLineString fid props (TypesGeoJsonFeatures.convertLineString g) mvtLines }
    Geospatial.MultiLine g    -> layer { TypesGeoJsonFeatures.mvtLines    = TypesMvtFeatures.mkLineString fid props (TypesGeoJsonFeatures.convertMultiLineString g) mvtLines }
    Geospatial.Polygon g      -> layer { TypesGeoJsonFeatures.mvtPolygons = TypesMvtFeatures.mkPolygon fid props (TypesGeoJsonFeatures.convertPolygon g) mvtPolygons }
    Geospatial.MultiPolygon g -> layer { TypesGeoJsonFeatures.mvtPolygons = TypesMvtFeatures.mkPolygon fid props (TypesGeoJsonFeatures.convertMultiPolygon g) mvtPolygons }
    Geospatial.Collection gs  -> Foldable.foldMap (convertGeometry layer fid props) gs

-- FeatureID

readFeatureID :: Maybe Geospatial.FeatureID -> Maybe Word
readFeatureID mfid =
  case mfid of
    Just (Geospatial.FeatureIDNumber x) -> Just (fromIntegral x)
    _                                   -> Nothing

convertId :: Maybe Geospatial.FeatureID -> STRef.STRef s Word -> MonadST.ST s Word
convertId mfid ops =
  case readFeatureID mfid of
    Just val -> pure val
    Nothing  -> do
      STRef.modifySTRef ops (+1)
      STRef.readSTRef ops
