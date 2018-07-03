
-- | Utilities for encrypting/decrypting byte arrays

module Dscp.Crypto.Encrypt
       ( -- * Passphrases
         PassPhrase
       , PassPhraseError (..)
       , getPassPhrase
       , mkPassPhrase
       , minPassPhraseLength
       , maxPassPhraseLength

         -- * Encrypted bytearray
       , Encrypted

         -- * Utility functions
       , DecryptionError (..)
       , encrypt
       , decrypt
       ) where

import Codec.Serialise (Serialise (..))
import Codec.Serialise.Decoding (decodeBytes)
import Codec.Serialise.Encoding (encodeBytes)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types (AEAD, AEADMode (AEAD_GCM), AuthTag (..), BlockCipher (aeadInit),
                            Cipher (cipherInit, cipherKeySize), IV, KeySizeSpecifier (..),
                            aeadSimpleDecrypt, aeadSimpleEncrypt, nullIV)
import Crypto.Error (onCryptoFailure)
import Crypto.Hash.Algorithms (SHA512 (..))
import qualified Crypto.KDF.PBKDF2 as PBKDF2
import Data.ByteArray (ByteArray, ByteArrayAccess)
import qualified Data.ByteArray as BA
import Data.Text.Buildable (build)
import Fmt ((+|), (|+))
import Text.Show (show)

import Dscp.Crypto.ByteArray (FromByteArray (..))

-------------------------------------------------------------
-- Passphrases
-------------------------------------------------------------

-- | Newtype for passphrase. Uses blind instances for
-- 'Buildable' and 'Show' in order to avoid accidental
-- appearance of actual passphrases in logs.
newtype PassPhrase = PassPhrase
    { getPassPhrase :: ByteString
    } deriving (Eq, Ord, Monoid, ByteArray, ByteArrayAccess)

instance Buildable PassPhrase where
    build _ = "<passphrase>"

instance Show PassPhrase where
    show _ = "<passphrase>"

-- | Minimum passphrase length. Should be enough.
minPassPhraseLength :: Int
minPassPhraseLength = 8

-- | Maximum passphrase length. To keep it sane.
maxPassPhraseLength :: Int
maxPassPhraseLength = 128

-- | Errors which might happen during passphrase construction.
data PassPhraseError
    = PassPhraseTooShort
        { peLength :: !Int }
    | PassPhraseTooLong
        { peLength :: !Int }
    deriving (Eq)

instance Buildable PassPhraseError where
    build PassPhraseTooShort {..} =
        "Passphrase is too short ("+|peLength|+
        " chars), minimum length is "+|minPassPhraseLength|+" chars."
    build PassPhraseTooLong {..} =
        "Passphrase is too long ("+|peLength|+
        " chars), maximum length is "+|maxPassPhraseLength|+" chars."

instance Show PassPhraseError where
    show = toString . pretty

instance Exception PassPhraseError

-- | Smart constructor for a passphrase
mkPassPhrase :: ByteString -> Either PassPhraseError PassPhrase
mkPassPhrase bs
    | lbs < minPassPhraseLength = Left $ PassPhraseTooShort lbs
    | lbs > maxPassPhraseLength = Left $ PassPhraseTooLong lbs
    | otherwise = Right $ PassPhrase bs
  where
    lbs = length bs

-------------------------------------------------------------
-- Encryption/decryption helper datatypes
-------------------------------------------------------------

-- | Datatype which combines ciphertext with cipher authentication tag.
data Encrypted ba = Encrypted
    { eAuthTag    :: !AuthTag
    , eCiphertext :: !ba
    } deriving (Eq)

-- | We have to define 'Serialise' instance for 'Encrypted' here,
-- because we don't export its constructor and field accessors.
instance FromByteArray ba => Serialise (Encrypted ba) where
    encode Encrypted {..} =
        encodeBytes (BA.convert eAuthTag) <>
        encodeBytes (BA.convert eCiphertext)
    decode = do
        eAuthTag <- AuthTag . BA.convert <$> decodeBytes
        eCiphertext <- either fail pure . fromByteArray =<< decodeBytes
        return Encrypted {..}

-------------------------------------------------------------
-- Encryption/decryption constants/salts
-------------------------------------------------------------

-- | Authentication tag length. Number 16 is the same as in the
-- `Crypto.MAC.Poly1305.Auth` tag datatype.
-- TODO: probably it can be made shorter without any problems?
authTagLength :: Int
authTagLength = 16

-- | Chosen cipher. We'll stick with AES256 for now.
-- TODO: are there better alternatives?
type CipherType = AES256

-- | Authentication header used for our encryption (empty one).
authHeader :: ByteString
authHeader = ""

-- | Salt used for key derivation from password.
passGenSalt :: ByteString
passGenSalt = "dscp-educator-pass-gen"

-- | AEAD mode used for our encryption scheme.
-- We use GCM mode, because it's the most modern and performant one
-- among available in Cryptonite, and it's also unencumbered
-- by patents.
--
-- See: AEAD_OCB: https://en.wikipedia.org/wiki/OCB_mode
--      AEAD_CCM: https://en.wikipedia.org/wiki/CCM_mode
--      AEAD_CWC: https://en.wikipedia.org/wiki/CWC_mode
--      AEAD_EAX: https://en.wikipedia.org/wiki/EAX_mode
--      AEAD_GCM: https://en.wikipedia.org/wiki/Galois/Counter_Mode
aeadMode :: AEADMode
aeadMode = AEAD_GCM

-- | Initial vector for chosen cipher.
initIV :: IV CipherType
initIV = nullIV

-------------------------------------------------------------
-- Encryption/decryption logic
-------------------------------------------------------------

-- | Get maximum key size allowed by chosen encryption scheme.
maxKeySize :: Int
maxKeySize = case cipherKeySize fakeCipher of
    KeySizeFixed size      -> size
    KeySizeRange _ maxSize -> maxSize
    KeySizeEnum sizes      -> maximum sizes
  where
    fakeCipher :: CipherType
    fakeCipher =
        error "impossible: cipher constructor is evaluated in `cipherKeySize`"

-- | Derive encryption key from passphrase using PBKDF2
-- with SHA-512 hash function.
keyFromPassPhrase :: PassPhrase -> ByteString
keyFromPassPhrase (PassPhrase pp) = PBKDF2.generate
    (PBKDF2.prfHMAC SHA512)
    (PBKDF2.Parameters
        500         -- Number of hash iterations
        maxKeySize) -- Encryption key size
    pp
    passGenSalt

-- | Prepare an AEAD context from a 'PassPhrase'.
prepareAEAD :: PassPhrase -> AEAD CipherType
prepareAEAD pp =
    let impossible err =
            error $ "encrypt: impossible: " <> Prelude.show err
        ppHashKey =
            keyFromPassPhrase pp
        cipher :: CipherType =
            onCryptoFailure impossible identity $
            cipherInit ppHashKey
    in onCryptoFailure impossible identity $
       aeadInit aeadMode cipher initIV

-- | Encrypt given 'ByteArray' with AES.
encrypt :: ByteArray ba => PassPhrase -> ba -> Encrypted ba
encrypt pp plaintext =
    let aead = prepareAEAD pp
        (eAuthTag, eCiphertext) =
            aeadSimpleEncrypt aead authHeader plaintext authTagLength
    in Encrypted {..}

-- | Decrypt given 'Encrypted' datatype or fail, if passphrase
-- doesn't match.
decrypt :: ByteArray ba => PassPhrase -> Encrypted ba -> Either DecryptionError ba
decrypt pp Encrypted {..} =
    let aead = prepareAEAD pp
    in maybeToRight PassPhraseInvalid $
       aeadSimpleDecrypt aead authHeader eCiphertext eAuthTag

-- | Errors which might occur during decryption
data DecryptionError = PassPhraseInvalid
    deriving (Eq)

instance Buildable DecryptionError where
    build PassPhraseInvalid = "Invalid passphrase is used for decryption"

instance Show DecryptionError where
    show = toString . pretty

instance Exception DecryptionError
