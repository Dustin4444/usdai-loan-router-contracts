// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {UpgradeableBeacon} from "@openzeppelin/contracts/proxy/beacon/UpgradeableBeacon.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {BaseTest} from "./Base.t.sol";

import {ReserveAccount} from "src/ReserveAccount.sol";
import {ReserveAccountFactory} from "src/ReserveAccountFactory.sol";
import {IReserveAccountFactory} from "src/interfaces/IReserveAccountFactory.sol";

contract ReserveAccountFactoryTest is BaseTest {
    /*------------------------------------------------------------------------*/
    /* Constants */
    /*------------------------------------------------------------------------*/

    uint256 internal constant RESERVES_REQUIRED = 5_000 * 1e18; /* 5k USDai reserve floor */
    bytes32 internal constant BORROWER_ROLE = keccak256("BORROWER_ROLE");

    /*------------------------------------------------------------------------*/
    /* State */
    /*------------------------------------------------------------------------*/

    address internal loanRouterAddress;
    address internal manager;
    ReserveAccount internal reserveImpl;
    UpgradeableBeacon internal beacon;
    ReserveAccountFactory internal factoryImpl;
    ReserveAccountFactory internal factory;

    /*------------------------------------------------------------------------*/
    /* Setup */
    /*------------------------------------------------------------------------*/

    function setUp() public override {
        super.setUp();

        /* Use a stable address in place of the loan router */
        loanRouterAddress = makeAddr("loanRouter");

        /* Set up the reserve account manager */
        manager = makeAddr("manager");

        vm.startPrank(users.deployer);

        /* Deploy the reserve account implementation administered by the admin */
        reserveImpl = new ReserveAccount(users.admin, loanRouterAddress);

        /* Deploy the reserve account beacon owned by the admin */
        beacon = new UpgradeableBeacon(address(reserveImpl), users.admin);

        /* Deploy the factory implementation pointed at the beacon */
        factoryImpl = new ReserveAccountFactory(address(beacon));

        /* Deploy the factory proxy */
        TransparentUpgradeableProxy factoryProxy = new TransparentUpgradeableProxy(
            address(factoryImpl),
            users.deployer,
            abi.encodeWithSelector(ReserveAccountFactory.initialize.selector, users.admin)
        );
        factory = ReserveAccountFactory(address(factoryProxy));

        vm.stopPrank();

        /* Grant the manager role */
        bytes32 managerRole = factory.RESERVE_ACCOUNT_MANAGER_ROLE();

        vm.prank(users.admin);
        factory.grantRole(managerRole, manager);
    }

    /*------------------------------------------------------------------------*/
    /* Helpers */
    /*------------------------------------------------------------------------*/

    function _create() internal returns (address) {
        vm.prank(manager);
        return factory.create(users.borrower, USDAI, RESERVES_REQUIRED);
    }

    /*------------------------------------------------------------------------*/
    /* Initialization */
    /*------------------------------------------------------------------------*/

    /* Test: initialize sets beacon and admin role */
    function test_Initialize() external view {
        assertEq(factory.beacon(), address(beacon));

        assertTrue(factory.hasRole(factory.DEFAULT_ADMIN_ROLE(), users.admin));
    }

    /* Test: initialize reverts on the implementation contract */
    function test_Initialize_RevertOnImplementation() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);

        factoryImpl.initialize(users.admin);
    }

    /* Test: initialize reverts when already initialized */
    function test_Initialize_RevertWhenAlreadyInitialized() external {
        vm.expectRevert(Initializable.InvalidInitialization.selector);

        factory.initialize(users.admin);
    }

    /* Test: initialize reverts on a zero admin */
    function test_Initialize_RevertZeroAdmin() external {
        ReserveAccountFactory implementation = new ReserveAccountFactory(address(beacon));

        vm.expectRevert(IReserveAccountFactory.InvalidAddress.selector);

        new TransparentUpgradeableProxy(
            address(implementation),
            users.deployer,
            abi.encodeWithSelector(ReserveAccountFactory.initialize.selector, address(0))
        );
    }

    /* Test: constructor reverts on a zero beacon */
    function test_Constructor_RevertZeroBeacon() external {
        vm.expectRevert(IReserveAccountFactory.InvalidAddress.selector);

        new ReserveAccountFactory(address(0));
    }

    /*------------------------------------------------------------------------*/
    /* Create */
    /*------------------------------------------------------------------------*/

    /* Test: create deploys and registers a reserve account */
    function test_Create() external {
        vm.expectEmit(false, false, false, false);
        emit IReserveAccountFactory.ReserveAccountCreated(address(0));

        address reserveAccountAddress = _create();

        assertTrue(factory.isReserveAccount(reserveAccountAddress));

        assertEq(factory.getReserveAccountCount(), 1);

        assertEq(factory.getReserveAccountAt(0), reserveAccountAddress);

        address[] memory reserveAccounts = factory.getReserveAccounts(0, 10);

        assertEq(reserveAccounts.length, 1);

        assertEq(reserveAccounts[0], reserveAccountAddress);
    }

    /* Test: create initializes the reserve account with the admin */
    function test_Create_InitializesReserveAccount() external {
        address reserveAccountAddress = _create();

        ReserveAccount reserveAccount = ReserveAccount(reserveAccountAddress);

        assertEq(reserveAccount.admin(), users.admin);

        assertEq(reserveAccount.loanRouter(), loanRouterAddress);

        assertEq(reserveAccount.currencyToken(), USDAI);

        assertTrue(IAccessControl(reserveAccountAddress).hasRole(BORROWER_ROLE, users.borrower));

        (uint256 required,) = reserveAccount.reserves();

        assertEq(required, RESERVES_REQUIRED);
    }

    /* Test: create tracks multiple reserve accounts */
    function test_Create_MultipleAccounts() external {
        address first = _create();

        vm.prank(manager);
        address second = factory.create(users.lender1, USDAI, RESERVES_REQUIRED);

        assertEq(factory.getReserveAccountCount(), 2);

        assertEq(factory.getReserveAccountAt(0), first);

        assertEq(factory.getReserveAccountAt(1), second);
    }

    /* Test: getReserveAccounts paginates by offset and count */
    function test_GetReserveAccounts_Paginates() external {
        address first = _create();

        vm.prank(manager);
        address second = factory.create(users.lender1, USDAI, RESERVES_REQUIRED);

        vm.prank(manager);
        address third = factory.create(users.lender2, USDAI, RESERVES_REQUIRED);

        /* First page of two */
        address[] memory firstPage = factory.getReserveAccounts(0, 2);

        assertEq(firstPage.length, 2);

        assertEq(firstPage[0], first);

        assertEq(firstPage[1], second);

        /* Count clamps to the remaining accounts */
        address[] memory secondPage = factory.getReserveAccounts(2, 10);

        assertEq(secondPage.length, 1);

        assertEq(secondPage[0], third);

        /* Offset past the end returns empty */
        address[] memory emptyPage = factory.getReserveAccounts(3, 10);

        assertEq(emptyPage.length, 0);
    }

    /* Test: create reverts for a non-manager */
    function test_Create_RevertNonManager() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                users.borrower,
                factory.RESERVE_ACCOUNT_MANAGER_ROLE()
            )
        );

        vm.prank(users.borrower);
        factory.create(users.borrower, USDAI, RESERVES_REQUIRED);
    }

    /*------------------------------------------------------------------------*/
    /* ERC165 */
    /*------------------------------------------------------------------------*/

    /* Test: supportsInterface advertises the factory and access control interfaces */
    function test_SupportsInterface() external view {
        assertTrue(factory.supportsInterface(type(IReserveAccountFactory).interfaceId));

        assertTrue(factory.supportsInterface(type(IAccessControl).interfaceId));
    }
}
