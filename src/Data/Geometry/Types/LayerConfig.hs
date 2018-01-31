{-# LANGUAGE DataKinds         #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeOperators     #-}

module Data.Geometry.Types.LayerConfig where

import           Data.Semigroup               ((<>))
import qualified Data.Text                    as DT
import qualified Options.Applicative          as OA

import qualified Data.Geometry.Types.Simplify as DGTS
import qualified Data.Geometry.Types.Types    as DGTT

data LayerConfig = LayerConfig
  { _layerInput          :: FilePath
  , _layerOutput         :: FilePath
  , _layerName           :: DT.Text
  , _layerZoom           :: DGTT.Pixels
  , _layerX              :: DGTT.Pixels
  , _layerY              :: DGTT.Pixels
  , _layerBuffer         :: DGTT.Pixels
  , _layerExtent         :: DGTT.Pixels
  , _layerQuantizePixels :: DGTT.Pixels
  , _layerSimplification :: DGTS.SimplificationAlgorithm
  } deriving (Show, Eq)

layerConfig :: OA.Parser LayerConfig
layerConfig = LayerConfig
  <$> OA.strOption
    ( OA.long "layer-input"
    <> OA.metavar "GEOJSON FILE"
    <> OA.help "Input GeoJSON file" )
  <*> OA.strOption
    ( OA.long "layer-output"
    <> OA.metavar "VECTOR FILE"
    <> OA.help "Output Mapnik Vector Tile file" )
  <*> OA.strOption
    ( OA.long "layer-name"
    <> OA.metavar "VECTOR LAYER NAME"
    <> OA.help "Name of Layer" )
  <*> OA.option OA.auto
    ( OA.long "layer-zoom"
    <> OA.help "Zoom level of layer"
    <> OA.metavar "INT" )
  <*> OA.option OA.auto
    ( OA.long "layer-x"
    <> OA.help "Longitude of layer"
    <> OA.metavar "INT" )
  <*> OA.option OA.auto
    ( OA.long "layer-y"
    <> OA.help "Latitude of layer"
    <> OA.metavar "INT" )
  <*> OA.option OA.auto
    ( OA.long "layer-buffer"
    <> OA.help "Buffer in pixels"
    <> OA.metavar "INT" )
  <*> OA.option OA.auto
    ( OA.long "layer-extent"
    <> OA.help "Layer size in pixels"
    <> OA.metavar "INT" )
  <*> OA.option OA.auto
    ( OA.long "layer-quantize-pixels"
    <> OA.help "Smallest pixel unit of layer"
    <> OA.metavar "INT" )
  <*> OA.strOption
    ( OA.long "layer-simplification"
    <> OA.help "Simplification algorithm: none, visvalingam or douglas-peucker"
  )
