// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.35;

import {DateTimeLib} from "solady/src/utils/DateTimeLib.sol";

import "./interfaces/ILoanRouterV2.sol";

/**
 * @title Schedule Logic
 * @author USD.AI Foundation
 */
library ScheduleLogic {
    /*------------------------------------------------------------------------*/
    /* Schedule */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Get the full deadline schedule
     * @param terms Loan terms
     * @param originationTimestamp UTC origination timestamp
     * @return hasStub True unless origination falls on the anchor calendar day
     * @return Array of UTC deadlines
     */
    function deadlines(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        uint64 originationTimestamp
    ) external pure returns (bool hasStub, uint64[] memory) {
        /* Locate the first monthly anchor after origination */
        (uint256 firstAnchorYear, uint256 firstAnchorMonth, bool stub) = _firstAnchor(terms, originationTimestamp);

        /* Floor for the loan duration */
        uint64 durationFloor =
            uint64(uint256(originationTimestamp) + uint256(terms.repaymentSpec.totalDurationDays) * 1 days);

        /* Count monthly anchors strictly before the duration floor */
        uint16 monthlyAnchorCount;
        {
            /* Year for pass 1 */
            uint256 year = firstAnchorYear;

            /* Month for pass 1 */
            uint256 month = firstAnchorMonth;

            /* Iterate until the next anchor lands at or after the floor */
            while (_anchorUtc(terms, year, month) < durationFloor) {
                /* Count one more monthly anchor */
                monthlyAnchorCount++;

                /* Step to the next month */
                (year, month) = _addMonth(year, month);
            }
        }

        /* Allocate (anchors before floor + closing anchor) and fill */
        uint64[] memory schedule = new uint64[](uint256(monthlyAnchorCount) + 1);
        {
            /* Year for pass 2 */
            uint256 year = firstAnchorYear;

            /* Month for pass 2 */
            uint256 month = firstAnchorMonth;

            /* Fill each monthly anchor before the floor in order */
            for (uint16 i; i < monthlyAnchorCount; i++) {
                /* Write the anchor at the current position */
                schedule[i] = _anchorUtc(terms, year, month);

                /* Step to the next month */
                (year, month) = _addMonth(year, month);
            }

            /* Closing anchor is the first anchor at or after the floor */
            schedule[monthlyAnchorCount] = _anchorUtc(terms, year, month);
        }

        return (stub, schedule);
    }

    /*------------------------------------------------------------------------*/
    /* Schedule (internal) */
    /*------------------------------------------------------------------------*/

    /**
     * @notice Find the first monthly anchor after origination
     * @param terms Loan terms
     * @param originationTimestamp UTC origination timestamp
     * @return year Year of the first anchor
     * @return month Month of the first anchor
     * @return hasStub True unless origination falls on the anchor calendar day
     */
    function _firstAnchor(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        uint64 originationTimestamp
    ) internal pure returns (uint256 year, uint256 month, bool hasStub) {
        /* Origination as a local-time timestamp (UTC + timezone offset) */
        uint256 originationLocal =
            uint256(int256(uint256(originationTimestamp)) + int256(terms.repaymentSpec.timezoneOffsetSeconds));

        /* Day-of-month placeholder for the destructure below */
        uint256 day;

        /* Decompose origination into local-time calendar parts */
        (year, month, day) = DateTimeLib.timestampToDate(originationLocal);

        /* Clamped anchor day for origination's month */
        uint256 anchorDayThisMonth = _anchorDay(terms, year, month);

        /* A stub exists unless origination falls on the anchor calendar day */
        hasStub = day != anchorDayThisMonth;

        /* If origination already passed the anchor, move to next month */
        if (day >= anchorDayThisMonth) (year, month) = _addMonth(year, month);
    }

    /**
     * @notice Resolve the anchor day-of-month, clamped to the month length
     * @param terms Loan terms
     * @param year Year
     * @param month Month (1 indexed)
     * @return Clamped anchor day
     */
    function _anchorDay(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        uint256 year,
        uint256 month
    ) internal pure returns (uint256) {
        /* Length of the target month */
        uint256 daysInMonth = DateTimeLib.daysInMonth(year, month);

        /* Clamp repaymentDay down to the month length */
        return uint256(terms.repaymentSpec.day) > daysInMonth ? daysInMonth : uint256(terms.repaymentSpec.day);
    }

    /**
     * @notice Resolve the monthly anchor as a UTC timestamp
     * @param terms Loan terms
     * @param year Year
     * @param month Month (1 indexed)
     */
    function _anchorUtc(
        ILoanRouterV2.LoanTermsV2 calldata terms,
        uint256 year,
        uint256 month
    ) internal pure returns (uint64) {
        /* Local-time anchor at midnight on the clamped day */
        uint256 localTimestamp = DateTimeLib.dateToTimestamp(year, month, _anchorDay(terms, year, month));

        /* Subtract timezone offset to return UTC */
        return uint64(uint256(int256(localTimestamp) - int256(terms.repaymentSpec.timezoneOffsetSeconds)));
    }

    /**
     * @notice Advance (year, month) by one month
     * @param year Year
     * @param month Month (1 indexed)
     */
    function _addMonth(
        uint256 year,
        uint256 month
    ) internal pure returns (uint256, uint256) {
        return (year + month / 12, (month % 12) + 1);
    }
}
