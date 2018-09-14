{-# LANGUAGE DeriveAnyClass    #-}
{-# LANGUAGE DeriveFoldable    #-}
{-# LANGUAGE DeriveFunctor     #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE NamedFieldPuns    #-}

-- | Sized Merkle tree implementation.
module Dscp.Crypto.MerkleTree
       ( MerkleSignature(..)
       , MerkleTree (..)
       , getMerkleRoot
       , fromFoldable
       , fromContainer
       , fromList

       , MerkleProof (..)
       , drawProofNode
       , mkMerkleProof
       , mkMerkleProofSingle
       , validateMerkleProof
       , getMerkleProofRoot
       , lookup
       , validateElementExistAt

       , MerkleNode (..)
       , drawMerkleTree
       , mkBranch
       , mkLeaf

       , EmptyMerkleTree
       , getEmptyMerkleTree
       , fillEmptyMerkleTree
       ) where

import Codec.Serialise (Serialise (..))
import Data.ByteArray (convert)
import Data.ByteString.Builder (Builder, byteString, word32LE)
import qualified Data.ByteString.Builder.Extra as Builder
import qualified Data.ByteString.Lazy as LBS
import qualified Data.Foldable as F (Foldable (..))
import qualified Data.Map as Map ((!))
import qualified Data.Set as Set
import Data.Tree as Tree (Tree (Node), drawTree)
import Fmt (build, (+|), (|+))
import qualified Text.Show

import Dscp.Crypto.Hash.Class (AbstractHash (..))
import Dscp.Crypto.Impl (HasHash, Hash, hash, unsafeHash)
import Dscp.Crypto.Serialise (Raw)


-- | Data type for root of sized merkle tree.
data MerkleSignature a = MerkleSignature
    { mrHash :: !(Hash Raw)  -- ^ returns root 'Hash' of Merkle Tree
    , mrSize :: !Word32      -- ^ size of root node,
                             --   size is defined as number of leafs in this subtree
    } deriving (Eq, Ord, Generic, Serialise, Functor, Foldable, Traversable, Typeable)

instance Buildable (MerkleSignature a) where
    build MerkleSignature{..} =
        "MerkleSignature { hash: " +| mrHash |+ "; size: " +| mrSize |+ " }"

instance Show (MerkleSignature a) where
    show = toString . pretty

data MerkleTree a
    = MerkleEmpty
    | MerkleTree !(MerkleNode a)
    deriving (Eq, Show, Functor, Generic, Serialise)


instance Foldable MerkleTree where
    foldMap _ MerkleEmpty    = mempty
    foldMap f (MerkleTree n) = F.foldMap f n

    null MerkleEmpty = True
    null _           = False

    length MerkleEmpty    = 0
    length (MerkleTree n) = fromIntegral (mrSize (mRoot n))

deriving instance Container (MerkleTree a)

type LeafIndex = Word32

data MerkleNode a
    = MerkleBranch
       { mRoot  :: !(MerkleSignature a)
       , mLeft  :: !(MerkleNode a)
       , mRight :: !(MerkleNode a) }
    | MerkleLeaf
       { mRoot  :: !(MerkleSignature a)
       , mIndex :: !LeafIndex
       , mVal   :: !a }
    deriving (Eq, Show, Functor, Generic, Serialise)

instance Foldable MerkleNode where
    foldMap f x = case x of
      MerkleLeaf {mVal}            -> f mVal
      MerkleBranch {mLeft, mRight} -> F.foldMap f mLeft `mappend` F.foldMap f mRight

mkLeaf :: HasHash a => LeafIndex -> a -> MerkleNode a
mkLeaf i a = MerkleLeaf
    { mVal   = a
    , mIndex = i
    , mRoot  = MerkleSignature (unsafeHash a) -- unsafeHash since we need to hash to ByteString
                                1 -- size of leaf node is 1
    }

mkBranch :: MerkleNode a -> MerkleNode a -> MerkleNode a
mkBranch l r = MerkleBranch
    { mLeft  = l
    , mRight = r
    , mRoot  = mkBranchRootHash (mRoot l) (mRoot r)
    }

mkBranchRootHash :: MerkleSignature a -- ^ left merkle root
                 -> MerkleSignature a -- ^ right merkle root
                 -> MerkleSignature a
mkBranchRootHash (MerkleSignature (AbstractHash hl) sl)
                 (MerkleSignature (AbstractHash hr) sr)
   = MerkleSignature
   (hash $ toLazyByteString $ mconcat
      [ word32LE sl
      , word32LE sr
      , byteString (convert hl)
      , byteString (convert hr) ])
   (sl + sr)
  where
    toLazyByteString :: Builder -> LBS.ByteString
    toLazyByteString = Builder.toLazyByteStringWith (Builder.safeStrategy 1024 4096) mempty

-- | Smart constructor for MerkleTree.
fromFoldable :: (HasHash a, Foldable t) => t a -> MerkleTree a
fromFoldable = fromList . F.toList

-- | Smart constructor for MerkleTree.
fromContainer :: (HasHash (Element t), Container t) => t -> MerkleTree (Element t)
fromContainer = fromList . toList

fromList :: HasHash a => [a] -> MerkleTree a
fromList [] = MerkleEmpty
fromList ls = MerkleTree (nodeFromList ls)

nodeFromList :: HasHash a => [a] -> MerkleNode a
nodeFromList lst = tree
  where
    (tree, []) = go (0, uLen - 1) `runState` lst

    uLen = fromIntegral $ length lst

    go (lo, hi)
        | lo == hi  = mkLeaf lo <$> pop
        | otherwise = mkBranch <$> go (lo, mid) <*> go (mid + 1, hi)
      where
        mid = (lo + hi) `div` 2

    pop = state $ \case
        []    -> error "nodeFromList: impossible"
        c : s -> (c, s)

-- | Returns root of merkle tree.
getMerkleRoot :: MerkleTree a -> MerkleSignature a
getMerkleRoot MerkleEmpty    = emptyHash
getMerkleRoot (MerkleTree x) = mRoot x

emptyHash :: MerkleSignature a
emptyHash = MerkleSignature (hash mempty) 0

data MerkleProof a
    = ProofBranch
        { pnSig   :: !(MerkleSignature a)
        , pnLeft  :: !(MerkleProof a)
        , pnRight :: !(MerkleProof a) }
    | ProofLeaf
        { pnSig :: !(MerkleSignature a)
        , pnVal :: !a
        }
    | ProofPruned
        { pnSig :: !(MerkleSignature a) }
    deriving (Eq, Show, Functor, Foldable, Traversable, Generic)

instance Serialise a => Serialise (MerkleProof a)

getMerkleProofRoot :: MerkleProof a -> MerkleSignature a
getMerkleProofRoot = pnSig

mkMerkleProofSingle :: forall a. MerkleTree a -- ^ merkle tree we want to construct a proof from
                              -> LeafIndex -- ^ leaf index used for proof
                              -> Maybe (MerkleProof a)
mkMerkleProofSingle t n = mkMerkleProof t (Set.fromList [n])

mkMerkleProof :: forall a. MerkleTree a -- ^ merkle tree we want to construct a proof from
                        -> Set LeafIndex -- ^ leaf index used for proof
                        -> Maybe (MerkleProof a)
mkMerkleProof MerkleEmpty _ = Nothing
mkMerkleProof (MerkleTree rootNode) n =
    case constructProof rootNode of
      ProofPruned _ -> Nothing
      x             -> Just x
  where
    constructProof :: MerkleNode a -> MerkleProof a
    constructProof (MerkleLeaf {..})
      | Set.member mIndex n = ProofLeaf mRoot mVal
      | otherwise = ProofPruned mRoot
    constructProof (MerkleBranch mRoot' mLeft' mRight') =
      case (constructProof mLeft', constructProof mRight') of
        (ProofPruned _, ProofPruned _) -> ProofPruned mRoot'
        (pL, pR)                       -> ProofBranch mRoot' pL pR

lookup :: LeafIndex -> MerkleProof a -> Maybe a
lookup index = \case
    ProofPruned {}        -> Nothing
    ProofLeaf   { pnVal } -> return pnVal

    ProofBranch { pnSig, pnLeft, pnRight } -> do
        let size = mrSize pnSig
        let border
              | odd size  = (size `div` 2) + 1
              | otherwise =  size `div` 2

        if   border > index
        then lookup  index           pnLeft
        else lookup (index - border) pnRight

validateElementExistAt :: Eq a => LeafIndex -> a -> MerkleProof a -> Bool
validateElementExistAt index value proof = lookup index proof == Just value

-- | Validate a merkle tree proof.
validateMerkleProof :: forall a. HasHash a => MerkleProof a -> MerkleSignature a -> Bool
validateMerkleProof proof treeRoot =
    computeMerkleRoot proof == Just treeRoot
  where
    computeMerkleRoot :: MerkleProof a -> Maybe (MerkleSignature a)
    computeMerkleRoot (ProofLeaf {..}) = do
      case MerkleSignature (unsafeHash pnVal) 1 == pnSig of
        True  -> Just pnSig
        False -> Nothing
    computeMerkleRoot (ProofPruned {..}) = Just pnSig
    computeMerkleRoot (ProofBranch pnRoot' pnLeft' pnRight') = do
      pnSigL <- computeMerkleRoot pnLeft'
      pnSigR <- computeMerkleRoot pnRight'
      case mkBranchRootHash pnSigL pnSigR == pnRoot' of
        True  -> Just pnRoot'
        False -> Nothing

-- | Debug print of tree.
drawMerkleTree :: (Show a) => MerkleTree a -> String
drawMerkleTree MerkleEmpty = "empty tree"
drawMerkleTree (MerkleTree n) = Tree.drawTree (asTree n)
  where
    asTree :: (Show a) => MerkleNode a -> Tree.Tree String
    asTree (MerkleBranch {..}) = Tree.Node (show mRoot) [asTree mLeft, asTree mRight]
    asTree  leaf               = Tree.Node (show leaf) []

-- | Debug print of proof tree.
drawProofNode :: (Show a) => Maybe (MerkleProof a) -> String
drawProofNode Nothing = "empty proof"
drawProofNode (Just p) = Tree.drawTree (asTree p)
  where
    asTree :: (Show a) => MerkleProof a -> Tree.Tree String
    asTree (ProofLeaf   {..}) = Tree.Node ("leaf, "   <> show pnSig) []
    asTree (ProofBranch {..}) = Tree.Node ("branch, " <> show pnSig) [asTree pnLeft, asTree pnRight]
    asTree (ProofPruned {..}) = Tree.Node ("pruned, " <> show pnSig) []

-- | Not a `newtype`, because DeriveAnyClass and GeneralizedNewtypeDeriving
--   are in conflict here.
data EmptyMerkleTree a = Empty (MerkleTree ())
    deriving (Eq, Show, Generic, Serialise)

-- | Replaces all values in the tree with '()'.
getEmptyMerkleTree :: MerkleTree a -> EmptyMerkleTree a
getEmptyMerkleTree = Empty . (() <$)

fillEmptyMerkleTree :: Map LeafIndex a -> EmptyMerkleTree a -> Maybe (MerkleProof a)
fillEmptyMerkleTree plugs (Empty sieve) =
    let
        keySet = Set.fromList (keys plugs)
        proof  = mkMerkleProof sieve keySet
        filled = fill <$> proof
    in
        filled
  where
    fill it = evalState (aux it) 0
      where
        aux = \case
          ProofBranch sig left right ->
              ProofBranch (coerseSig sig) <$> aux left <*> aux right

          ProofLeaf sig () ->
              ProofLeaf (coerseSig sig) . (plugs Map.!) <$> next

          ProofPruned sig ->
              ProofPruned (coerseSig sig) <$ skip (mrSize sig)

        next   = state $ \i -> (i,  i + 1)
        skip n = state $ \i -> ((), i + n)

    coerseSig sig = error "coerseSig: 'MerkleSignature a' has 'a' inside!" <$> sig
