import Test.DocTest

main = doctest ["-pgmL", "markdown-unlit", "-isrc", "test/README.lhs"]
