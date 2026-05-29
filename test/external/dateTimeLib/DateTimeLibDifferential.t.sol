// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {DateTimeLib} from "solady/src/utils/DateTimeLib.sol";

/*
 * CONSTRAINTS
 * -----------
 * Oracle coverage: Python datetime is valid for years 1..9999, so external-oracle coverage is
 *   1970..9999.
 *
 * Correctness only: this test feeds only valid, in-range inputs. It does NOT cover fail-open
 *   behavior (e.g. daysInMonth(y, 13) silently returning garbage). Input validation is a
 *   separate concern - a green run is not proof of input safety.
 *
 * Algorithm vs bytecode: Python-only unit tests verify the algorithm against the stdlib. This
 *   FFI test verifies the deployed Solady bytecode against an independent oracle. We keep both.
 *
 * Profile gate: this test requires ffi = true and only runs under FOUNDRY_PROFILE=exhaustive.
 *   It is a no-op (skipped) under any other profile.
 */
contract DateTimeLibDifferentialTest is Test {
    /*------------------------------------------------------------------------*/
    /* Test: exhaustive narrow window [1970, 2030] */
    /*------------------------------------------------------------------------*/

    function test__Exhaustive_NarrowWindow() public {
        // Skip unless running under the exhaustive profile
        string memory forgeProfile = vm.envOr("FOUNDRY_PROFILE", string("default"));

        // Skip if not the exhaustive profile
        vm.skip(keccak256(bytes(forgeProfile)) != keccak256(bytes("exhaustive")));

        // One batch call returns 2 words per day for all days in [1970, 2030]
        string[] memory batchArgs = new string[](5);

        // python3 executable
        batchArgs[0] = "python3";

        // Script path relative to repo root (forge working directory)
        batchArgs[1] = "test/external/dateTimeLib/datetime_oracle.py";

        // Batch mode
        batchArgs[2] = "batch";

        // Range start
        batchArgs[3] = "1970";

        // Range end
        batchArgs[4] = "2030";

        // Fetch all oracle data in one subprocess call
        bytes memory batchData = vm.ffi(batchArgs);

        // Track position in the packed buffer (2 words per day, 64 bytes per record)
        uint256 dayIndex = 0;

        for (uint256 year = 1970; year <= 2030; year++) {
            for (uint256 month = 1; month <= 12; month++) {
                // Read oracle daysInMonth from word 1 of the first slot for this month
                uint256 oracleDaysInMonth;

                assembly {
                    oracleDaysInMonth := mload(add(batchData, add(64, mul(dayIndex, 64))))
                }

                // Solady daysInMonth must match oracle
                assertEq(DateTimeLib.daysInMonth(year, month), oracleDaysInMonth);

                for (uint256 day = 1; day <= oracleDaysInMonth; day++) {
                    // Read expected timestamp for this day from word 0 of the current slot
                    uint256 expectedTimestamp;

                    assembly {
                        expectedTimestamp := mload(add(batchData, add(32, mul(dayIndex, 64))))
                    }

                    // dateToTimestamp must match oracle for this date
                    assertEq(DateTimeLib.dateToTimestamp(year, month, day), expectedTimestamp);

                    // timestampToDate must recover the year
                    (uint256 recoveredYear, uint256 recoveredMonth, uint256 recoveredDay) =
                        DateTimeLib.timestampToDate(expectedTimestamp);

                    // Year recovered
                    assertEq(recoveredYear, year);

                    // Month recovered
                    assertEq(recoveredMonth, month);

                    // Day recovered
                    assertEq(recoveredDay, day);

                    // Advance to next day's record
                    dayIndex++;
                }
            }
        }

        // Report total dates verified
        console.log("DateTimeLib differential: SUCCESS");
        console.log("Dates tested:", dayIndex);
    }
}
