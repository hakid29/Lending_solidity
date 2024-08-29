// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// - ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
// - 이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50%, liquidation threshold는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
// - 필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
// - 청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
// - 실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
// - 주요 기능 인터페이스는 아래를 참고해 만드시면 됩니다.

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
//import {UpsideOracle} from "test/LendingTest.t.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract UpsideAcademyLending {
    IPriceOracle public priceOracle;
    address public usdc;
    uint256 public totalUSDCDeposits;
    uint256 public totalEtherDeposits;
    uint256 public reserve;

    mapping(address => uint256) public etherDeposits;
    mapping(address => uint256) public usdcDeposits;
    mapping(address => uint256) public usdcBorrows;

    uint256 public constant LOAN_TO_VALUE = 50; // 50%
    uint256 public constant LIQUIDATION_THRESHOLD = 75;
    uint256 public constant LIQUIDATION_BONUS = 10; // 10%

    uint256 public constant block_interest = 100063995047075019; // 100.06xxxx * 10^77
    uint256 public constant day_interest = 100100000000000000; // 100.1 * 10^77
    uint256 public constant denominator = 1e77;

    constructor(IPriceOracle _priceOracle, address _usdc) {
        priceOracle = _priceOracle;
        usdc = _usdc;
    }

    function initializeLendingProtocol(address token) external payable {
        require(msg.value > 0, "Must send ether to initialize");
        reserve = msg.value;
        ERC20(usdc).transferFrom(msg.sender, address(this), msg.value); // ?
    }

    function deposit(address token, uint256 amount) external payable {
        require(amount > 0, "Amount must be greater than 0");
        if (token == address(0)) { // Ether deposit
            require(msg.value == amount, "Sent ether must equal amount");
            etherDeposits[msg.sender] += msg.value;
            totalEtherDeposits += msg.value;
        } else if (token == usdc) { // USDC deposit
            ERC20(usdc).transferFrom(msg.sender, address(this), amount);
            usdcDeposits[msg.sender] += amount;
            totalUSDCDeposits += amount;
        } else {
            revert("Unsupported token");
        }
    }

    function borrow(address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be borrowed");

        uint256 collateralValueInUSDC = (etherDeposits[msg.sender] * priceOracle.getPrice(address(0x00))) / 1 ether;
        uint256 maxBorrow = (collateralValueInUSDC * LOAN_TO_VALUE) / 100; // 50%

        require(usdcBorrows[msg.sender] + amount <= maxBorrow, "Insufficient collateral");
        require(amount <= totalUSDCDeposits - reserve, "Insufficient liquidity");

        usdcBorrows[msg.sender] += amount;
        ERC20(usdc).transfer(msg.sender, amount);
    }

    function repay(address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be repaid");

        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        usdcBorrows[msg.sender] -= amount;
    }

    function withdraw(address token, uint256 amount) external {
        if (token == address(0)) { // Ether withdrawal
            uint256 collateralValueInUSDC = (etherDeposits[msg.sender] * priceOracle.getPrice(address(0))) / 1 ether;
            uint256 borrowedAmount = usdcBorrows[msg.sender];
            require((collateralValueInUSDC - ((priceOracle.getPrice(address(0)) * amount) / 1 ether)) * LIQUIDATION_THRESHOLD / 100 >= borrowedAmount, "Collateral is locked");

            etherDeposits[msg.sender] -= amount;
            totalEtherDeposits -= amount;
            payable(msg.sender).transfer(amount);
        } else if (token == usdc) { // USDC withdrawal
            require(usdcDeposits[msg.sender] >= amount, "Insufficient balance");
            usdcDeposits[msg.sender] -= amount;
            totalUSDCDeposits -= amount;
            ERC20(usdc).transfer(msg.sender, amount);
        } else {
            revert("Unsupported token");
        }
    }

    function liquidate(address borrower, address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be used for liquidation");

        uint256 collateralValueInUSDC = (etherDeposits[borrower] * priceOracle.getPrice(address(0))) / 1 ether;
        uint256 borrowedAmount = usdcBorrows[borrower];
        uint256 amount_ = amount * 1e18 / priceOracle.getPrice(address(usdc));

        require(collateralValueInUSDC < (borrowedAmount * 100) / LIQUIDATION_THRESHOLD, "Loan is not eligible for liquidation");
        require((amount_ == borrowedAmount && borrowedAmount < 100 ether) || (amount_ <= borrowedAmount * 1 / 4), "Invalid amount");

        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        usdcBorrows[borrower] -= amount_;
        etherDeposits[borrower] -= (amount_ * 1 ether) / priceOracle.getPrice(address(0));

        totalEtherDeposits -= (amount_ * 1 ether) / priceOracle.getPrice(address(0));
        payable(msg.sender).transfer((amount_ * 1 ether) / priceOracle.getPrice(address(0)));
    }

    function getAccruedSupplyAmount(address token) external view returns (uint256) {
        if (token == usdc) {
            return totalUSDCDeposits + (totalEtherDeposits * priceOracle.getPrice(address(0))) / 1 ether - reserve;
        } else {
            revert("Unsupported token");
        }
    }
}
