module Disciplina.DB.Real.Functions
       ( -- * Closing/opening
         openRocksDB
       , closeRocksDB
       , openNodeDB
       , closeNodeDB
         -- * Reading/writing
       , rocksGetBytes
       , rocksPutBytes
       , rocksDelete
       ) where

import Universum

import qualified Database.RocksDB as Rocks

import Disciplina.DB.Class (MonadDB (..), MonadDBRead (..))
import Disciplina.DB.Real.Types (DB (..), DBType, NodeDB (..))

-----------------------------------------------------------
-- Opening/closing
-----------------------------------------------------------

openRocksDB :: MonadIO m => FilePath -> m DB
openRocksDB path = do
    let rocksReadOpts = Rocks.defaultReadOptions
        rocksWriteOpts = Rocks.defaultWriteOptions
        rocksOptions = (Rocks.defaultOptions path)
            { Rocks.optionsCreateIfMissing = True
            , Rocks.optionsCompression = Rocks.NoCompression
            }
    rocksDB <- Rocks.open rocksOptions
    return DB {..}

closeRocksDB :: MonadIO m => DB -> m ()
closeRocksDB = Rocks.close . rocksDB

openNodeDB :: MonadIO m => DBType -> FilePath -> m NodeDB
openNodeDB dbType path = NodeDB dbType <$> openRocksDB path

closeNodeDB :: MonadIO m => NodeDB -> m ()
closeNodeDB = closeRocksDB . _ndbDatabase

------------------------------------------------------------
-- Reading/writing
------------------------------------------------------------

-- | Read ByteString from RocksDb using given key.
rocksGetBytes :: MonadIO m => ByteString -> DB -> m (Maybe ByteString)
rocksGetBytes key DB {..} = Rocks.get rocksDB rocksReadOpts key

-- | Write ByteString to RocksDB for given key.
rocksPutBytes :: MonadIO m => ByteString -> ByteString -> DB -> m ()
rocksPutBytes k v DB {..} = Rocks.put rocksDB rocksWriteOpts k v

-- | Delete element from RocksDB for given key.
rocksDelete :: MonadIO m => ByteString -> DB -> m ()
rocksDelete k DB {..} = Rocks.delete rocksDB rocksWriteOpts k
