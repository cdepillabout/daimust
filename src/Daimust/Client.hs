module Daimust.Client
where

import           ClassyPrelude        hiding (many, some)

import           Control.Lens         (at, folded, folding, indices, ix, to,
                                       traversed, universe, (&), (.~), (?~),
                                       (^.), (^..), (^?), (^?!))
import           Data.Default         (def)
import           Network.URI          (parseURIReference)
import           Network.Wreq.Lens    (responseBody)
import           Text.Megaparsec
import           Text.Megaparsec.Char
import           Text.Xml.Lens

import           Debug.Trace          as Debug

import           Daimust.Crawler
import qualified Daimust.Crawler      as Crawler
import           Daimust.Display


-- * Data types

data Settings =
  Settings
  { loginUrl :: URI
  , username :: Text
  , password :: Text
  }
  deriving (Eq, Show)


data Client =
  Client
  { settings :: Settings
  , basePage :: Maybe Response
  , state    :: Crawler.State
  , verbose  :: Bool
  }


data Attendance =
  Attendance
  { date  :: Text
  , day   :: Text
  , dow   :: Text
  , hours :: Text
  , note  :: Text
  }
  deriving (Eq, Show)

-- * Table config

attendancesTable :: DisplayTableConfig
attendancesTable =
  def
  { headerRows = [0]
  , dropRows = [1, 2]
  , pickColumns = Just [0, 1, 10, 12]
  }

-- * Operations

newClient :: Settings -> IO Client
newClient settings = do
  state <- runCrawler getState
  pure Client { basePage = Nothing, verbose = True, ..}

authenticate :: Client -> IO Client
authenticate Client {..} = do
  runCrawler $ do
    res <-
      login settings
      >>= gotoEntrance
    state' <- getState
    pure Client { basePage = Just res, state = state', .. }

headerTexts :: Client -> [Text]
headerTexts Client {..} = fromMaybe (pure []) $ do
  page <- basePage
  table <- lastMay $ page ^.. responseBody . html . selected "table"
  let DisplayTableConfig { headerRows } = attendancesTable
  pure $ (table ^.. selected "tr") ^.. traversed . indices (`elem` headerRows) . to (unwords . rowTexts)


listAttendances :: Client -> [Attendance]
listAttendances Client {..} = do
  fromMaybe [] $ do
    page <- basePage
    table <- lastMay $ page ^.. responseBody . html . selected "table"
    pure . catMaybes $ parseItem <$> table ^.. selected "tr"


-- * Low level functions

login :: Settings -> Crawler Response
login Settings {..} = do
  res <- get loginUrl
  let form = res ^?! responseBody . html . forms
      form' = form
              & fields . at "PN_ID" ?~ username
              & fields . at "PN_PASS" ?~ password
  submit form'

gotoEntrance :: Response -> Crawler Response
gotoEntrance res = do
  res1 <- do
    let form' = res ^?! responseBody . html . forms
                & fields . at "ACTION" ?~ "3"
    submit form'

  res2 <- do
    let onloadP = do
          void $ many (notChar '(')
          between (char '(') (char ')') $ many (
            between (char '\'') (char '\'') (many (notChar '\'')) <* many (char ',')
            )

    let Just (action', username, password) = do
          onload <- res1 ^. responseBody . html . selected "body" . attr "onLoad"
          [u, p, url] <- (parseMaybe @()) onloadP onload
          url' <- parseURIReference url
          pure (url', pack u, pack p)

    let form' = res1 ^?! responseBody . html . forms
                & action .~ action'
                & fields . at "pn0001" ?~ username
                & fields . at "pn0002" ?~ password
    submit form'

  res3 <- do
    let Just src' = lastMay $ res2 ^.. responseBody . html . frames . src
    get src'
  -- traverse_ printLink $ res3 ^.. responseBody . html . links

  res4 <- do
    let Just link' = lastMay $ res3 ^.. responseBody . html . links
    click link'
  -- traverse_ printLink $ res4 ^.. responseBody . html . links
  -- traverse_ printForm $ res4 ^.. responseBody . html . forms

  pure res4



rowTexts :: Dom -> [Text]
rowTexts tr = do
  td <- tr ^.. selected "td"
  let text' = td ^. folding universe . text
  pure $ bool "" (unwords $ words text') ((length . filter (not . null . concat . words) $ lines text') == 1)

parseItem :: Dom -> Maybe Attendance
parseItem tr = headMay . catMaybes $ do
  comment <- tr ^.. selected "" . comments
  pure $ do
    let cells = rowTexts tr
    day <- cells ^? ix 0
    dow <- cells ^? ix 1
    hours <- cells ^? ix 10
    note <- cells ^? ix 12
    flip (parseMaybe @()) comment $ do
      between (space *> string "ymd[") (string "]" *> space) $ do
        y <- some digitChar <* char '-'
        m <- some digitChar <* char '-'
        d <- some digitChar <* char '-'
        void $ some (notChar ']')
        pure $ Attendance { date = pack y <> pack m <> pack d, .. }
