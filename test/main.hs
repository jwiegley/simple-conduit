module Main where

import Control.Concurrent
import Data.IPCVar
import Data.IPCVar.File as File
import Data.IPCVar.Shm as Shm
import System.Posix.Process
import Test.Hspec

main :: IO ()
main = hspec $ do
    describe "file backend" $
        it "reads and writes values" $ do
            var <- File.newIPCVar (10 :: Int)
            _ <- forkProcess $ writeIPCVar var 20
            threadDelay 2000000
            x <- readIPCVar var
            x `shouldBe` 20
            deleteIPCVar var

    describe "shm backend" $
        it "reads and writes values" $ do
            Prelude.putStrLn $ "shm main.hs:23.."
            var <- Shm.newIPCVar (10 :: Int)
            Prelude.putStrLn $ "shm main.hs:25.."
            _ <- forkProcess $ writeIPCVar var 20
            Prelude.putStrLn $ "shm main.hs:27.."
            threadDelay 2000000
            Prelude.putStrLn $ "shm main.hs:29.."
            x <- readIPCVar var
            Prelude.putStrLn $ "shm main.hs:31.."
            x `shouldBe` 20
            Prelude.putStrLn $ "shm main.hs:33.."
            deleteIPCVar var
            Prelude.putStrLn $ "shm main.hs:35.."
