# USDai Loan Router Contracts

## Usage

Clone:

```shell
$ git clone --recursive https://github.com/metastreet-labs/usdai-loan-router-contracts.git
```

Build:

```shell
$ forge build
```

Test:

```shell
$ forge test
$ FOUNDRY_PROFILE=exhaustive forge test --ffi --match-contract DateTimeLibDifferentialTest
```

## Update Submodules

```shell
$ git submodule deinit --force .
$ git submodule update --init --recursive
```

## License

USDai Loan Router Contracts are primarily BUSL-1.1 [licensed](LICENSE). Interfaces are MIT licensed.
