{-# LANGUAGE OverloadedStrings #-}

module Data.Geometry.ClipSpec where

import qualified Data.Vector                   as Vector
import qualified Geography.VectorTile          as VectorTile
import           Test.Hspec                    (Spec, describe, it, shouldBe)

import qualified Data.Geometry.Clip            as GeometryClip
import qualified Data.Geometry.Types.Geography as GeometryGeography

import qualified Data.Geometry.SpecHelper      as SpecHelper

brokenPoly :: VectorTile.Polygon
brokenPoly = VectorTile.Polygon (SpecHelper.tupleToPts brokenPolyPts) mempty

giantPoly :: VectorTile.Polygon
giantPoly = VectorTile.Polygon (SpecHelper.tupleToPts giantPolyPts) mempty

polyPts :: [(Int, Int)]
polyPts = [ (50,150),  (200, 50)
          , (350,150), (350,300)
          , (250,300), (200,250)
          , (150,350), (100,250)
          , (100,200)
          ]

innerPolyPts :: [(Int, Int)]
innerPolyPts = [(75,200),(250,250),(250,150),(75,150)]

poly :: VectorTile.Polygon
poly = VectorTile.Polygon (SpecHelper.tupleToPts polyPts) mempty

resultPolyPts :: [(Int, Int)]
resultPolyPts = [(100,200),(100,116),(124,100),(275,100),(300,116),(300,300),(250,300),(200,250),(175,300),(125,300),(100,250),(100,200)]

innerPolyResultPts :: [(Int, Int)]
innerPolyResultPts = [(100,150),(100,207),(250,250),(250,150),(100,150)]

resultPoly :: VectorTile.Polygon
resultPoly = VectorTile.Polygon (SpecHelper.tupleToPts resultPolyPts) mempty

polyWithInner :: VectorTile.Polygon
polyWithInner = VectorTile.Polygon (SpecHelper.tupleToPts polyPts) (Vector.fromList [VectorTile.Polygon (SpecHelper.tupleToPts innerPolyPts) mempty])

turningPointTestPolyPts :: [(Int, Int)]
turningPointTestPolyPts = [(125,125),(175,175),(75,225),(25,175),(125,125)]

turningPointTestPoly :: VectorTile.Polygon
turningPointTestPoly = VectorTile.Polygon (SpecHelper.tupleToPts turningPointTestPolyPts) mempty

turningPointTestClippedPolyPts :: [(Int, Int)]
turningPointTestClippedPolyPts = [(125,125),(175,175),(124,200),(100,200),(100,137),(125,125)]

turningPointTestClippedPoly :: VectorTile.Polygon
turningPointTestClippedPoly = VectorTile.Polygon (SpecHelper.tupleToPts turningPointTestClippedPolyPts) mempty

myClipPts :: GeometryGeography.BoundingBoxPts
myClipPts = GeometryGeography.BoundingBoxPts (VectorTile.Point 100 100) (VectorTile.Point 200 200)

resultPolyWithInner :: VectorTile.Polygon
resultPolyWithInner = VectorTile.Polygon (SpecHelper.tupleToPts resultPolyPts) (Vector.fromList [VectorTile.Polygon (SpecHelper.tupleToPts innerPolyResultPts) mempty])

brokenPolyPts :: [(Int, Int)]
brokenPolyPts = [(-512,-400),(96,-400),(96,-904),(-512,-904),(-512,-400)]

giantPolyPts :: [(Int, Int)]
giantPolyPts = [(2176,-128),(2176,2176),(-128,2176),(-128,-128)]

polyClipPts :: GeometryGeography.BoundingBoxPts
polyClipPts = GeometryGeography.BoundingBoxPts (VectorTile.Point 100 100) (VectorTile.Point 300 300)

brokenClipPts :: GeometryGeography.BoundingBoxPts
brokenClipPts = GeometryGeography.BoundingBoxPts (VectorTile.Point (-128) (-128)) (VectorTile.Point 2176 2176)

giantClipPts :: GeometryGeography.BoundingBoxPts
giantClipPts = GeometryGeography.BoundingBoxPts (VectorTile.Point (-128) (-128)) (VectorTile.Point 2176 2176)

linesTst :: Vector.Vector VectorTile.LineString
linesTst = Vector.fromList
  [ VectorTile.LineString (SpecHelper.tupleToPts [(11, 11), (59, 59)])
  , VectorTile.LineString (SpecHelper.tupleToPts [(0, 0), (0, 100)])
  , VectorTile.LineString (SpecHelper.tupleToPts [(5, 5), (45, 50), (90, 140)])
  , VectorTile.LineString (SpecHelper.tupleToPts [(0, 0), (10, 10)])
  , VectorTile.LineString (SpecHelper.tupleToPts [(50, 50), (0, 10)])
  , VectorTile.LineString (SpecHelper.tupleToPts [(0, 0), (60, 60)])]

lineClipPts :: GeometryGeography.BoundingBoxPts
lineClipPts = GeometryGeography.BoundingBoxPts (VectorTile.Point 10 10) (VectorTile.Point 60 60)

spec :: Spec
spec = do
  testClipLine
  testClipPolygon
  testClipPolygonWithInterior
  testManyClipPolygon

testClipLine :: Spec
testClipLine =
  describe "simple line test" $ do
    let resultLines = Vector.fromList
          [ VectorTile.LineString (SpecHelper.tupleToPts [(10, 10), (60, 60)])
          , VectorTile.LineString (SpecHelper.tupleToPts [(50, 50), (10, 18)])
          , VectorTile.LineString (SpecHelper.tupleToPts [(10, 10), (10, 10)])
          , VectorTile.LineString (SpecHelper.tupleToPts [(10, 11), (45, 50), (50, 60)])
          , VectorTile.LineString (SpecHelper.tupleToPts [(11, 11), (59, 59)])
          ]
    it "Cohen Sutherland returns clipped line" $ do
      let actual = GeometryClip.clipLinesCs lineClipPts linesTst
      actual `shouldBe` resultLines
    it "Liang Barsky returns clipped line" $ do
      let actual = GeometryClip.clipLinesLb lineClipPts linesTst
      actual `shouldBe` resultLines
    it "QuickClip returns clipped line" $ do
      let
        actual = GeometryClip.clipLinesQc lineClipPts linesTst
      actual `shouldBe` resultLines
    it "Nicholl-Lee-Nicholl returns clipped line" $ do
      let
        actual = GeometryClip.clipLinesNLN lineClipPts linesTst
      actual `shouldBe` resultLines

testClipPolygon :: Spec
testClipPolygon =
  describe "simple polygon test" $ do
    it "Simple - Returns clipped polygon" $
      GeometryClip.clipPolygon polyClipPts poly `shouldBe` Just resultPoly
    it "Simple - Negative polygon" $ do
      let actual = GeometryClip.clipPolygon brokenClipPts brokenPoly
      actual `shouldBe` Nothing
    it "Simple - Maximum polygon" $ do
      let actual = GeometryClip.clipPolygon giantClipPts giantPoly
          resultPts = [(-128,-128),(2176,-128),(2176,2176),(-128,2176),(-128,-128)]
          result = VectorTile.Polygon (SpecHelper.tupleToPts resultPts) mempty
      actual `shouldBe` Just result
    it "Simple - Turning point test" $
      GeometryClip.clipPolygon myClipPts turningPointTestPoly `shouldBe` Just turningPointTestClippedPoly
    -- it "NLN - Returns clipped polygon" $
    --   GeometryClip.clipPolygonNLN polyClipPts poly `shouldBe` Just resultPoly
    it "NLN - Negative polygon" $ do
      let actual = GeometryClip.clipPolygonNLN brokenClipPts brokenPoly
      actual `shouldBe` Nothing
    it "NLN - Maximum polygon" $ do
      let actual = GeometryClip.clipPolygonNLN giantClipPts giantPoly
          resultPts = [(-128,-128),(2176,-128),(2176,2176),(-128,2176),(-128,-128)]
          result = VectorTile.Polygon (SpecHelper.tupleToPts resultPts) mempty
      actual `shouldBe` Just result
    -- it "NLN - Turning point test" $
    --   GeometryClip.clipPolygonNLN myClipPts turningPointTestPoly `shouldBe` Just turningPointTestClippedPoly


testClipPolygonWithInterior :: Spec
testClipPolygonWithInterior =
  describe "simple polygon with inner test" $
    it "Returns clipped polygon and inner polygon" $
      GeometryClip.clipPolygon polyClipPts polyWithInner `shouldBe` Just resultPolyWithInner


manyClipPts :: GeometryGeography.BoundingBoxPts
manyClipPts = GeometryGeography.BoundingBoxPts (VectorTile.Point 100 100) (VectorTile.Point 200 200)
    
poly1 :: VectorTile.Polygon
poly1 = VectorTile.Polygon (SpecHelper.tupleToPts a) mempty
  where
    a = [(125,125),(175,175),(75,225),(25,175),(125,125)]

result1 :: VectorTile.Polygon
result1 = VectorTile.Polygon (SpecHelper.tupleToPts a) mempty
  where
    a = [(125,125),(175,175),(124,200),(100,200),(100,137),(125,125)]

result1b :: VectorTile.Polygon
result1b = VectorTile.Polygon (SpecHelper.tupleToPts a) mempty
  where
    a = [(125,125),(175,175),(125,200),(100,200),(100,137),(125,125)]
  
testManyClipPolygon :: Spec
testManyClipPolygon = 
  describe "many polygon test" $ do
    it "Simple - polygon 1" $
      GeometryClip.clipPolygon manyClipPts poly1 `shouldBe` Just result1
    it "NLN - polygon 1" $
      GeometryClip.clipPolygonNLN manyClipPts poly1 `shouldBe` Just result1b
