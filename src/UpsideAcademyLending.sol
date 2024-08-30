// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

// - ETH를 담보로 사용해서 USDC를 빌리고 빌려줄 수 있는 서비스를 구현하세요.
// - 이자율은 24시간에 0.1% (복리), Loan To Value (LTV)는 50%, liquidation threshold는 75%로 하고 담보 가격 정보는 “참고코드"를 참고해 생성한 컨트랙트에서 갖고 오세요.
// - 필요한 기능들은 다음과 같습니다. Deposit (ETH, USDC 입금), Borrow (담보만큼 USDC 대출), Repay (대출 상환), Liquidate (담보를 청산하여 USDC 확보)
// - 청산 방법은 다양하기 때문에 조사 후 bad debt을 최소화에 가장 적합하다고 생각하는 방식을 적용하고 그 이유를 쓰세요.
// - 실제 토큰을 사용하지 않고 컨트랙트 생성자의 인자로 받은 주소들을 토큰의 주소로 간주합니다.
// - 주요 기능 인터페이스는 아래를 참고해 만드시면 됩니다.

import "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "forge-std/Test.sol";

interface IPriceOracle {
    function getPrice(address token) external view returns (uint256);
}

contract UpsideAcademyLending {
    struct User {
        uint256 etherDeposit;
        uint256 usdcDeposit;
        uint256 usdcBorrow;
        uint256 lastUpdate;
        uint256 updatedTotalDebt;
    }

    User[] Users;
    uint256 userCount;
    IPriceOracle public priceOracle;
    address public usdc;
    uint256 public totalUSDCDeposits;
    uint256 public totalDebt;

    mapping(address => uint256) matchUserId;

    uint256 public constant blockInterest = 100000013881950033; // (1.001의 7200제곱근) * 10^17
    uint256 public constant dayInterest = 100100000000000000; // 100.1 * 10^17

    constructor(IPriceOracle _priceOracle, address _usdc) {
        priceOracle = _priceOracle;
        usdc = _usdc;
    }

    function initializeLendingProtocol(address token) external payable {
        require(msg.value > 0, "Must send ether to initialize");
        ERC20(usdc).transferFrom(msg.sender, address(this), msg.value);
    }

    function updateBorrow(User memory user_, uint256 index) internal {
        // totaldebt update
        if (user_.usdcBorrow != 0 && block.number != user_.lastUpdate) {
            uint usdcBorrow_ = user_.usdcBorrow;
            uint afterblock = block.number - user_.lastUpdate;

            uint day = afterblock / 7200; // 1 day = 7200 block
            uint withinday = afterblock % 7200;

            // 최적화
            uint dayInterest_ = dayInterest;
            uint blockInterest_ = blockInterest;

            assembly {
                for { let i := 0 } lt(i, day) { i := add(i, 1) } {
                    usdcBorrow_ := div(mul(usdcBorrow_, dayInterest_), 100000000000000000)
                }

                for { let j := 0 } lt(j, withinday) { j := add(j, 1) } {
                    usdcBorrow_ := div(mul(usdcBorrow_, blockInterest_), 100000000000000000)
                }
            }

            // update
            totalDebt += (usdcBorrow_ - user_.usdcBorrow);
            user_.usdcBorrow = usdcBorrow_;
        }
        user_.lastUpdate = block.number;
        Users[index] = user_;
    }

    function updateDeposit(User memory user_, uint256 index) internal {
        if (user_.usdcDeposit != 0) {
            user_.usdcDeposit = user_.usdcDeposit + (totalDebt - user_.updatedTotalDebt) * user_.usdcDeposit / totalUSDCDeposits;
            user_.updatedTotalDebt = totalDebt;
            Users[index] = user_;
        }
    }

    function updateAll() internal {
        uint oldTotalDebt = totalDebt;
        for (uint i = 0; i < Users.length; i++) {
            User memory user_ = Users[i];
            updateBorrow(user_, i);
        }
        if (oldTotalDebt != totalDebt) {
            for (uint i = 0; i < Users.length; i++) {
                User memory user_ = Users[i];
                updateDeposit(user_, i);
            }
        }
    }

    function deposit(address token, uint256 amount) external payable {
        // deposit할 때는 update할 필요 없음
        User memory user_;
        if (matchUserId[msg.sender] != 0) {
            user_ = Users[matchUserId[msg.sender]-1];
        } else { // initialize user
            matchUserId[msg.sender] = userCount + 1;
            user_.updatedTotalDebt = totalDebt;
            user_.lastUpdate = block.number;
            Users.push(user_);
            userCount++;
        }

        require(amount > 0, "Amount must be greater than 0");
        if (token == address(0)) { // Ether deposit
            require(msg.value == amount, "Sent ether must equal amount");
            user_.etherDeposit += msg.value;
            Users[matchUserId[msg.sender]-1] = user_;
        } else if (token == usdc) { // USDC deposit
            ERC20(usdc).transferFrom(msg.sender, address(this), amount);
            user_.usdcDeposit += amount;
            totalUSDCDeposits += amount;
            Users[matchUserId[msg.sender]-1] = user_;
        } else {
            revert("Unsupported token");
        }
    }

    function borrow(address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be borrowed");
        require(matchUserId[msg.sender] != 0, "Do other thing first");

        updateAll();
        User memory user_ = Users[matchUserId[msg.sender]-1];

        uint256 collateralValueInUSDC = (user_.etherDeposit * priceOracle.getPrice(address(0x00))) / 1 ether;
        uint256 maxBorrow = (collateralValueInUSDC * 50) / 100; // loan to value

        require(user_.usdcBorrow + amount <= maxBorrow, "Insufficient collateral");
        require(amount <= totalUSDCDeposits, "Insufficient liquidity");

        ERC20(usdc).transfer(msg.sender, amount);
        user_.usdcBorrow += amount;
        Users[matchUserId[msg.sender]-1] = user_;
    }

    function repay(address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be repaid");
        require(matchUserId[msg.sender] != 0, "Do other thing first");

        updateAll();

        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        Users[matchUserId[msg.sender]-1].usdcBorrow -= amount;
    }

    function withdraw(address token, uint256 amount) external {
        require(matchUserId[msg.sender] != 0, "Do other thing first");

        updateAll();
        User memory user_ = Users[matchUserId[msg.sender]-1];

        if (token == address(0)) { // Ether withdrawal
            uint256 collateralValueInUSDC = (user_.etherDeposit * priceOracle.getPrice(address(0))) / 1 ether;
            uint256 borrowedAmount = user_.usdcBorrow;
            require((collateralValueInUSDC - ((priceOracle.getPrice(address(0)) * amount) / 1 ether)) * 75 / 100 >= borrowedAmount, "Collateral is locked");

            payable(msg.sender).transfer(amount);
            user_.etherDeposit -= amount;
            Users[matchUserId[msg.sender]-1] = user_;
        } else if (token == usdc) { // USDC withdrawal
            require(user_.usdcDeposit >= amount, "Insufficient balance");

            ERC20(usdc).transfer(msg.sender, amount);
            totalUSDCDeposits -= amount;
            user_.usdcDeposit -= amount;
            Users[matchUserId[msg.sender]-1] = user_;
        } else {
            revert("Unsupported token");
        }
    }

    function liquidate(address borrower, address token, uint256 amount) external {
        require(token == usdc, "Only USDC can be used for liquidation");

        updateAll();
        User memory user_ = Users[matchUserId[borrower]-1];

        uint256 collateralValueInUSDC = (user_.etherDeposit * priceOracle.getPrice(address(0))) / 1 ether;
        uint256 borrowedAmount = user_.usdcBorrow;
        uint256 amount_ = amount * 1e18 / priceOracle.getPrice(address(usdc));

        require(collateralValueInUSDC < (borrowedAmount * 100) / 75, "Loan is not eligible for liquidation");
        require((amount_ == borrowedAmount && borrowedAmount < 100 ether) || (amount_ <= borrowedAmount * 1 / 4), "Invalid amount");

        ERC20(usdc).transferFrom(msg.sender, address(this), amount);
        user_.usdcBorrow -= amount_;
        user_.etherDeposit -= (amount_ * 1 ether) / priceOracle.getPrice(address(0));
        Users[matchUserId[borrower]-1] = user_;

        payable(msg.sender).transfer((amount_ * 1 ether) / priceOracle.getPrice(address(0)));
    }

    function getAccruedSupplyAmount(address token) external returns (uint256) {
        require(token == usdc, "Invalid token");
        if (matchUserId[msg.sender] == 0) {
            return 0;
        }

        updateAll();
        User memory user_ = Users[matchUserId[msg.sender]-1];
        return Users[matchUserId[msg.sender]-1].usdcDeposit;
    }
}
