{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications    #-}

-- | Golden and round-trip testing of 'FromCBOR' and 'ToCBOR' instances

module Test.Bcc.Binary.Helpers.GoldenRoundTrip
  ( goldenTestCBOR
  , goldenTestCBORExplicit
  , goldenTestExplicit
  , roundTripsCBORShow
  , roundTripsCBORBuildable
  , compareHexDump
  , deprecatedGoldenDecode
  )
where

import Bcc.Prelude
import Test.Bcc.Prelude

import qualified Codec.CBOR.Decoding as D
import qualified Data.ByteString.Lazy.Char8 as BS
import Formatting.Buildable (Buildable(..))
import Hedgehog
  (MonadTest, Property, eval, property, success, tripping, withTests, (===))
import Hedgehog.Internal.Property (failWith)
import Hedgehog.Internal.Show
  (LineDiff, lineDiff, mkValue, renderLineDiff, showPretty)

import Bcc.Binary
  ( Decoder
  , DecoderError
  , Encoding
  , FromCBOR(..)
  , ToCBOR(..)
  , decodeFull
  , decodeFullDecoder
  , serialize
  , serializeEncoding
  )
import qualified Prelude
import Text.Show.Pretty (Value(..))


type HexDump = LByteString

type HexDumpDiff = [LineDiff]

renderHexDumpDiff :: HexDumpDiff -> [Char]
renderHexDumpDiff = Prelude.unlines . fmap renderLineDiff

-- | Diff two 'HexDump's by comparing lines pairwise
hexDumpDiff :: HexDump -> HexDump -> Maybe HexDumpDiff
hexDumpDiff x y = do
  xs <- sequence (mkValue <$> BS.lines x)
  ys <- sequence (mkValue <$> BS.lines y)
  pure $ concatMap (uncurry lineDiff) $ zipWithPadding
    (String "")
    (String "")
    xs
    ys

zipWithPadding :: a -> b -> [a] -> [b] -> [(a, b)]
zipWithPadding a b (x : xs) (y : ys) = (x, y) : zipWithPadding a b xs ys
zipWithPadding a _ []       ys       = zip (repeat a) ys
zipWithPadding _ b xs       []       = zip xs (repeat b)

-- | A custom version of '(===)' for 'HexDump's to get prettier diffs
compareHexDump :: (MonadTest m, HasCallStack) => HexDump -> HexDump -> m ()
compareHexDump x y = do
  ok <- withFrozenCallStack $ eval (x == y)
  if ok then success else withFrozenCallStack $ failHexDumpDiff x y

-- | Fail with a nice line diff of the two HexDumps
failHexDumpDiff :: (MonadTest m, HasCallStack) => HexDump -> HexDump -> m ()
failHexDumpDiff x y = case hexDumpDiff x y of
  Nothing -> withFrozenCallStack $ failWith Nothing $ Prelude.unlines
    ["━━━ Not Equal ━━━", showPretty x, showPretty y]
  Just dif -> withFrozenCallStack $ failWith Nothing $ renderHexDumpDiff dif

-- | Check that the 'encode' and 'decode' function of the 'Bi' instances work as
-- expected w.r.t. the give reference data, this is, given a value @x::a@, and
-- a file path @fp@:
--
-- - The encoded data should coincide with the contents of the @fp@.
-- - Decoding @fp@ should give as a result @x@
--
goldenTestCBOR
  :: forall a
  . (FromCBOR a, ToCBOR a, Eq a, Show a, HasCallStack)
  => a
  -> FilePath
  -> Property
goldenTestCBOR = withFrozenCallStack
  $ goldenTestCBORExplicit (label $ Proxy @a) toCBOR fromCBOR


-- | Variant of 'goldenTestBi' using custom encode and decode functions.
--
-- This is required for the encode/decode golden-tests for types that do no
-- have a 'Bi' instance.
--
goldenTestCBORExplicit
  :: forall a
  . (Eq a, Show a, HasCallStack)
  => Text
  -- ^ Label for error reporting when decoding.
  -> (a -> Encoding)
  -> (forall s . Decoder s a)
  -> a
  -> FilePath
  -> Property
goldenTestCBORExplicit eLabel enc dec =
  goldenTestExplicit (serializeEncoding . enc) fullDecoder
  where
  fullDecoder :: LByteString -> Either DecoderError a
  fullDecoder = decodeFullDecoder eLabel dec

goldenTestExplicit
  :: forall a
  . (Eq a, Show a, HasCallStack)
  => (a -> BS.ByteString)
  -> (BS.ByteString -> Either DecoderError a)
  -> a
  -> FilePath
  -> Property
goldenTestExplicit encode decode x path = withFrozenCallStack $ do
  let bs' = encodeWithIndex . encode $ x
  withTests 1 . property $ do
    bs <- liftIO $ BS.readFile path
    let target = decodeBase16 bs
    compareHexDump bs bs'
    fmap decode target === Just (Right x)

-- | Round trip test a value (any instance of 'FromCBOR', 'ToCBOR', and 'Show'
--   classes) by serializing it to a ByteString and back again and that also has
--   a 'Show' instance. If the 'a' type has both 'Show' and 'Buildable'
--   instances, it's best to use this version.
roundTripsCBORShow
  :: (FromCBOR a, ToCBOR a, Eq a, MonadTest m, Show a, HasCallStack)
  => a
  -> m ()
roundTripsCBORShow x = withFrozenCallStack $ tripping x serialize decodeFull

-- | Round trip (via ByteString) any instance of the 'FromCBOR' and 'ToCBOR'
--   class that also has a 'Buildable' instance.
roundTripsCBORBuildable
  :: (FromCBOR a, ToCBOR a, Eq a, MonadTest m, Buildable a, HasCallStack)
  => a
  -> m ()
roundTripsCBORBuildable a =
  withFrozenCallStack $ trippingBuildable a serialize decodeFull

deprecatedGoldenDecode
  :: HasCallStack => Text -> (forall s . D.Decoder s ()) -> FilePath -> Property
deprecatedGoldenDecode lbl decoder path =
  withFrozenCallStack $ withTests 1 . property $ do
    bs <- decodeBase16 <$> liftIO (BS.readFile path)
    fmap (decodeFullDecoder lbl decoder) bs === Just (Right ())
