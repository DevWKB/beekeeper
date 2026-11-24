{-# LANGUAGE    LambdaCase        #-}
{-# LANGUAGE    BangPatterns      #-}
{-# LANGUAGE    QualifiedDo       #-}
{-# LANGUAGE    OverloadedStrings #-}
{-# LANGUAGE    ViewPatterns      #-}
{-# OPTIONS_GHC -Wno-orphans      #-}
module BK.BKMap
    (BKMap,
     Bookmark(..),    
     BKType(..),  
     bookmark,
     parseBKType,
     addBookmark,
     removeBookmark,
     renameBookmark,
     findBookmark,
     recentBookmarks,
     isAlias,
     isBookmark,
     showBKMap,
     maxOffsetBKMap,
     showBKType,
     filterBKMap,
     filterLabels,
     emptyBKMap,
     bookmarks,
     insertBK) where

-- External Imports:
import GHC.Generics             (Generic)
import Data.Text                (Text)
import Data.Csv                 (FromRecord(..), 
                                 ToRecord(..), 
                                 FromField (..), 
                                 Field, 
                                 ToField (..),                              
                                 ToNamedRecord (..),                              
                                 NamedRecord, 
                                 Parser,
                                 namedRecord, 
                                 (.=))
import System.FilePath          (isValid,
                                 isAbsolute,
                                 normalise,
                                 dropTrailingPathSeparator)
import Data.Bifunctor           (Bifunctor(bimap))
import Data.Time.Calendar       (Day, 
                                 addDays)
import Data.Time.Format.ISO8601 (ISO8601 (iso8601Format), 
                                 Format (formatShowM),
                                 formatParseM)

import  Data.Text                 qualified as DT 
import  Data.Char                 qualified as DT
import  Data.Map                  qualified as Map

--
-- * Internal Imports

import BK.Lib qualified as Lib
import Data.String (fromString)

_undefined :: a
_undefined = Prelude.undefined

data BKType = BKAlias 
            | BKBookmark
    deriving (Generic)

showBKType :: BKType -> Text
showBKType BKAlias    = "alias"
showBKType BKBookmark = "bookmark"

-- | The number of spaces needed to properly space `BKType`'s when pretty
-- printing bookmarks.
--
-- This is equivalent to `length (showBKType bktype) + 1`.
offsetBKType :: BKType -> Int
offsetBKType BKAlias    = 4
offsetBKType BKBookmark = 1

instance Show BKType where
    show :: BKType -> String
    show BKAlias = "alias"
    show BKBookmark = "bookmark"

instance FromField  BKType where
    parseField :: Field -> Parser BKType
    parseField = parseField' . (bimap DT.unpack id) . parseBKType . Lib.byteStringToTextUTF8
        where
            parseField' (Right bt) = return bt
            parseField' (Left err) = fail err

parseBKType 
    :: Text
    -> Either Text BKType
parseBKType s 
        | s == "alias"    = return BKAlias
        | s == "bookmark" = return BKBookmark
        | otherwise       = Left $ s <> " is not a valid bookmark type"

instance ToField BKType where
  toField :: BKType -> Field
  toField = fromString . show

instance FromField Day where
    parseField :: Field -> Parser Day
    parseField s = 
        case formatParseM iso8601Format (Lib.byteStringToStringUTF8 s) of
            Nothing -> _fail $ s <> " is not a valid ISO8601 date"
            Just day -> return day
        where
            _fail = fail . Lib.byteStringToStringUTF8

instance ToField Day where
    toField :: Day -> Field
    toField day = 
        case formatShowM iso8601Format day of
            Nothing -> error "[toField]: failed to pretty print day"
            Just s -> Lib.stringUTF8ToByteString s

data Bookmark = Bookmark {
    bkType     :: !BKType,
    bkLabel    :: !Text,    
    bkTarget   :: !Text,
    bkCreated  :: !Day,
    bkLastUsed :: !Day
} deriving (Generic)

validBookmarkLabel 
    :: DT.Text 
    -> Bool
validBookmarkLabel (DT.uncons->Nothing) = True
validBookmarkLabel (DT.uncons->Just (h,t)) | DT.isAlpha h 
    = flip DT.all t $ DT.isAlphaNum `Lib.orF` (flip DT.elem "_-")
validBookmarkLabel (DT.uncons->Just (_,_)) | otherwise = False

bookmark 
    :: BKType 
    -> Text 
    -> Text 
    -> Day 
    -> Day 
    -> Either Text Bookmark
bookmark bktype bklabel bktarget bkcreated bklastused 
    = if validBookmarkLabel bklabel 
      then if not (DT.null bktarget)
           then Right $ Bookmark { 
                          bkType     = bktype, 
                          bkLabel    = bklabel, 
                          bkTarget   = bktarget, 
                          bkCreated  = bkcreated, 
                          bkLastUsed = bklastused 
                        }
           else Left $ "empty target for label \"" <> bklabel <> "\""
      else Left $ "invalid label " <> (DT.show bklabel)

instance Show Bookmark where
    show :: Bookmark -> String  
    show (Bookmark bkT bkL bkTar _ _) 
        = (show bkT) <> " " <> (DT.unpack bkL) <> "=" <> (show bkTar) 

instance FromRecord Bookmark
instance ToRecord   Bookmark

updateBookmarkTarget :: Bookmark -> Text -> Bookmark
updateBookmarkTarget (Bookmark bktype bklabel _ bkcreated bklastused) bktarget
    = Bookmark { 
        bkType     = bktype,          
        bkLabel    = bklabel, 
        bkTarget   = bktarget, 
        bkCreated  = bkcreated, 
        bkLastUsed = bklastused 
    }

instance ToNamedRecord Bookmark where
    toNamedRecord :: Bookmark -> NamedRecord
    toNamedRecord b = namedRecord [
        "type" .= bkType b, 
        "label" .= bkLabel b, 
        "target" .= bkTarget b,
        "created-data" .= bkCreated b,
        "last-used" .= bkLastUsed b]

data BKMap = BKMap {
    getBKMap :: Map.Map Text Bookmark,
    getBKMapMaxLabelLength :: Int
}

emptyBKMap :: BKMap 
emptyBKMap = BKMap { 
        getBKMap = Map.empty, 
        getBKMapMaxLabelLength = 0 
    }

bookmarks :: BKMap -> [Bookmark]
bookmarks = Map.elems . getBKMap

insertBK :: Bookmark -> BKMap -> BKMap
insertBK bk bkMap = BKMap { 
        getBKMap = Map.insert newLabel bk $ getBKMap bkMap, 
        getBKMapMaxLabelLength = (max (maxOffsetBKMap bkMap) (DT.length newLabel)) 
    }
    where
        newLabel = bkLabel bk

maxLabels :: Map.Map Text Bookmark -> Int
maxLabels = Prelude.maximum . Prelude.map DT.length . Map.keys

deleteBookmark :: Text -> BKMap -> BKMap
deleteBookmark label bkMap = BKMap {
        getBKMapMaxLabelLength = newMax,
        getBKMap = newMap
    }
    where    
        newMap = Map.delete label $ getBKMap bkMap
        newMax = Prelude.maximum . Prelude.map DT.length . Map.keys $ newMap

lookupBookmark :: Text -> BKMap -> Prelude.Maybe Bookmark
lookupBookmark label = Map.lookup label . getBKMap

foldlBKMap :: (a -> Bookmark -> a)
           -> a
           -> BKMap
           -> a
foldlBKMap f s = Map.foldl f s . getBKMap

filterBKMap :: (Bookmark -> Bool)
            -> BKMap
            -> BKMap
filterBKMap _pred bkMap = BKMap {
        getBKMap = newMap,
        getBKMapMaxLabelLength = newMax
    }
    where
        _map = getBKMap bkMap
        newMap = Map.filter _pred _map
        newMax = maxLabels newMap

filterLabels 
    :: (Text -> Bool)
    -> BKMap
    -> [Text]
filterLabels _filter (getBKMap->bkMap) = 
    Map.keys $ Map.filter (_filter . bkLabel) bkMap

toAssocList :: BKMap -> [(Text,Bookmark)]
toAssocList (BKMap _map _) = Map.assocs _map

maxOffsetBKMap :: BKMap -> Int
maxOffsetBKMap = getBKMapMaxLabelLength 

labelOffset :: Int -> Text -> Int
labelOffset maxOffset label = maxOffset - (DT.length label)

toBKAssignment :: Int -> BKType -> Text -> Text -> Text
toBKAssignment maxOffset bktype label target = 
       (showBKType bktype) <> DT.replicate (offsetBKType bktype) " "
    <> label <> DT.replicate (labelOffset maxOffset label) " " <> " = " <> (DT.show target)

showBKMap :: Int -> BKMap -> Text
showBKMap maxOffset bkMap = _showBKMap $ toAssocList bkMap
    where
        _showBKMap :: [(Text,Bookmark)] -> Text
        _showBKMap [] = ""
        _showBKMap [(label,bk)] 
             = toBKAssignment maxOffset (bkType bk) label (bkTarget bk)
        _showBKMap ((label,bk):bks) 
             = toBKAssignment maxOffset (bkType bk) label (bkTarget bk) <> "\n"
            <> _showBKMap bks

bookmarkAsAssignment :: Bookmark -> Text
bookmarkAsAssignment b = toBKAssignment 0 (bkType b) (bkLabel b) (bkTarget b)

addBookmark :: Bookmark
            -> FilePath
            -> BKMap
            -> Either Text BKMap
addBookmark b homedir bkMap 
    | isBookmark b = do
        let path = dropTrailingPathSeparator . normalise $ DT.unpack (bkTarget b)
        if isValid path
        then  if isAbsolute path
              then return $ insertBK (updateBookmarkTarget b (DT.pack path)) bkMap
              else return $ insertBK (updateBookmarkTarget b (DT.pack . Lib.expandHomeDirectory homedir $ path)) bkMap
        else Left $ "bookmark is not a valid path " <> bookmarkAsAssignment b
    | isAlias b = Right $ insertBK b bkMap
    | otherwise = Left $ "invalid bookmark " <> bookmarkAsAssignment b

removeBookmark :: Text
               -> BKMap
               -> BKMap
removeBookmark = deleteBookmark 

renameBookmark :: Text
               -> Text
               -> BKMap
               -> Maybe BKMap
renameBookmark old_label new_label bkMap 
    = do old_value <- findBookmark old_label bkMap
         pure . insertBK (old_value {bkLabel = new_label}) 
              . deleteBookmark old_label
              $ bkMap

findBookmark :: Text
             -> BKMap
             -> Prelude.Maybe Bookmark
findBookmark = lookupBookmark

partitionBKMap
    :: (Bookmark -> Bool)
    -> BKMap
    -> (BKMap,BKMap)
partitionBKMap pick = foldlBKMap which (emptyBKMap,emptyBKMap)
    where
        which :: (BKMap,BKMap) 
              -> Bookmark 
              -> (BKMap,BKMap)
        which (p1,p2) bk | pick bk   = (insertBK bk p1,p2)
        which (p1,p2) bk | otherwise = (p1,insertBK bk p2)

isAlias :: Bookmark -> Bool
isAlias (Bookmark BKAlias _ _ _ _) = True
isAlias _ = False

isBookmark :: Bookmark -> Bool
isBookmark (Bookmark BKBookmark _ _ _ _) = True
isBookmark _ = False

recentBookmarks :: Day
                -> BKMap
                -> (BKMap,BKMap)
recentBookmarks today bkMap = partitionBKMap isAlias $ filterBKMap recentBookmark bkMap
    where                        
        recentBookmark :: Bookmark -> Bool
        recentBookmark (Bookmark _ _ _ _ lastUsedDay) = 
            addDays (-10) today <= lastUsedDay && lastUsedDay <= today
