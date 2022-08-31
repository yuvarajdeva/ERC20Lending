// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.14;


import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC721.sol";
import "@openzeppelin/contracts/interfaces/IERC1155.sol";


contract LendingContract {

    enum AssetType{ERC1155, ERC721}

    event Lend(uint256 loanId, address nftAddress, uint256 tokenId, uint256 assetPrice, uint256 platformFee);

    event LoanRepayment(uint256 loanId, address nftAddress, uint256 tokenId, uint256 interestFee, uint256 loanAmount); 

    event LoanOverdued(uint256 loanId, address nftAddress, uint256 tokenId);

    address public owner;

    bytes4 private constant _ERC721_RECEIVED = 0x150b7a02;

    uint256 public totalNumLoans;

    uint256 public totalActiveLoans;

    uint256 public sellerFee = 50;

    uint256 public buyerFee = 50;

    mapping(uint256 => LoanDetail) public loans;
    mapping(uint256 => bool) public loanIdStatus;
    mapping(uint256 => bool) public loanRepaidOrLiquidated;

    mapping(uint256 => bool) private usedNonce;

    struct Sign {
        uint8 v;
        bytes32 r;
        bytes32 s;
        uint256 nonce;        
    }

    struct Order {
        address borrower;
        address lender;
        address erc20Address;
        address nftAddress;
        AssetType nftType;
        uint256 unitPrice;
        uint256 amount;
        uint256 tokenId;
        uint256 qty;
        uint256 loanDuration;
        uint256 interestRateDuration;
    }

    struct LoanDetail {
        uint256 loanId;
        address nftAddress;
        AssetType nftType;
        uint256 tokenId;
        address borrower;
        address lender;
        uint256 loanPrincipalAmount;
        uint256 loanRepaymentAmount;
        uint256 loanStartTime;
        uint256 loanDuration;
        address loanERC20Address;
        uint256 qty;
        uint256 loanInterestForDuration;
    }

    constructor() {
        owner = msg.sender;
    }

    modifier onlyOwner {
        require(msg.sender == owner, "Ownable: owner sign verification failed");
        _;
    }

    function getSigner(bytes32 hash, Sign memory sign) internal pure returns(address) {
        return ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), sign.v, sign.r, sign.s); 
    }

    function verifyLenderSign( address lender, address borrower, address nftAddress, uint256 tokenId, uint256 amount, uint256 qty, Sign memory sign) internal view {
        bytes32 hash = keccak256(abi.encodePacked(this, lender, borrower, tokenId, nftAddress, amount, qty, sign.nonce));
        require(lender == getSigner(hash, sign), "lender sign verification failed");
    }

    function verifySign(uint256 tokenId, address caller, Sign memory sign) internal view {
        bytes32 hash = keccak256(abi.encodePacked(this, caller, tokenId, sign.nonce));
        require(owner == ecrecover(keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)), sign.v, sign.r, sign.s), "Owner sign verification failed");
    }

    function inititateLend (Order memory order, Sign memory sign) external returns(bool){
        require(!usedNonce[sign.nonce],"Nonce: Invalid Nonce");
        usedNonce[sign.nonce] = true;
        verifyLenderSign(order.lender, msg.sender, order.nftAddress, order.tokenId, order.amount, order.qty, sign);

        totalNumLoans += 1;
        order.loanDuration = order.loanDuration * 1 days;

        uint price = order.amount * 1000 / (1000 + buyerFee);
        require(order.amount >= price, "Subtraction overflow");
        uint _buyerFee = order.amount - price;
        uint _sellerFee = price * sellerFee / 1000;
        uint256 platformFee = _buyerFee + _sellerFee;

        require(price >= _sellerFee, "Subtraction overflow");
        uint256 assetPrice = price - _sellerFee;

        uint256 interest = platformFee + (order.amount *  order.interestRateDuration / 1000);

        uint256 id = totalNumLoans;

        loans[id] = LoanDetail(
            id,
            order.nftAddress,
            order.nftType,
            order.tokenId,
            msg.sender,
            order.lender,
            order.unitPrice,
            order.unitPrice + interest,
            block.timestamp,
            order.loanDuration,
            order.erc20Address,
            order.qty,
            order.interestRateDuration            
        );

        loanIdStatus[id] = true;
        totalActiveLoans += 1;


        if(order.nftType == AssetType.ERC721) { 
            IERC721(order.nftAddress).safeTransferFrom(order.borrower, address(this), order.tokenId);
        }
        if(order.nftType == AssetType.ERC1155) {
            IERC1155(order.nftAddress).safeTransferFrom(order.borrower, address(this), order.tokenId, order.qty, "");
        }
        if(assetPrice > 0){
            IERC20(order.erc20Address).transferFrom(order.lender, order.borrower, assetPrice);
        }
        if(platformFee > 0) {
            IERC20(order.erc20Address).transferFrom(order.lender, owner, platformFee);
        }

        emit Lend(id, order.nftAddress, order.tokenId, assetPrice, platformFee );

        return true;
    }

    function loanRepayment(uint256 _loanId, Sign memory sign) external returns(bool) {
        require(!usedNonce[sign.nonce],"Nonce: Invalid Nonce");
        usedNonce[sign.nonce] = true;
        verifySign(_loanId, msg.sender, sign);
        require(loanIdStatus[_loanId], "Invalid loanId");
        require(!loanRepaidOrLiquidated[_loanId], "Loan has been already repaid or liquidated");
        require(msg.sender == loans[_loanId].borrower,"Current user and borrower is not same ");

        uint256 timeDiff = block.timestamp - loans[_loanId].loanStartTime;

        uint256 interestDue = calculateInterest(loans[_loanId].loanPrincipalAmount, loans[_loanId].loanRepaymentAmount, timeDiff, loans[_loanId].loanDuration, loans[_loanId].loanInterestForDuration);

        uint256 amount = loans[_loanId].loanPrincipalAmount + interestDue;
        if(amount > 0) {
            IERC20(loans[_loanId].loanERC20Address).transferFrom(loans[_loanId].borrower, loans[_loanId].lender, amount);
        }

        if(loans[_loanId].nftType == AssetType.ERC721) { 
            IERC721(loans[_loanId].nftAddress).safeTransferFrom(address(this), loans[_loanId].borrower, loans[_loanId].tokenId);
        }
        if(loans[_loanId].nftType == AssetType.ERC1155) {
            IERC1155(loans[_loanId].nftAddress).safeTransferFrom(address(this), loans[_loanId].borrower, loans[_loanId].tokenId, loans[_loanId].qty, "");
        }

        loanRepaidOrLiquidated[_loanId] = true;
        loanIdStatus[_loanId] = false;
        totalActiveLoans -= 1;
        emit LoanRepayment(_loanId, loans[_loanId].nftAddress, loans[_loanId].tokenId, interestDue, loans[_loanId].loanPrincipalAmount);
        delete loans[_loanId];

        return true;
    }

    function loanOverdue(uint256 _loanId, Sign memory sign) external returns(bool) {

        require(!usedNonce[sign.nonce],"Nonce: Invalid Nonce");
        usedNonce[sign.nonce] = true;
        verifySign(_loanId, msg.sender, sign);

        require(loanIdStatus[_loanId],"Invalid LoanId");
        require(msg.sender == loans[_loanId].lender,"Current User and lender is not same");
        require(!loanRepaidOrLiquidated[_loanId], "Loan has been already repaid or liquidated");
        uint256 loanMaturityDate = loans[_loanId].loanStartTime + loans[_loanId].loanDuration;
        require(block.timestamp > loanMaturityDate, "loan not overdue yet");
        
        if(loans[_loanId].nftType == AssetType.ERC721) {
            IERC721(loans[_loanId].nftAddress).safeTransferFrom(address(this), loans[_loanId].lender, loans[_loanId].tokenId);
        }

        if(loans[_loanId].nftType == AssetType.ERC1155) {
            IERC1155(loans[_loanId].nftAddress).safeTransferFrom(address(this), loans[_loanId].lender, loans[_loanId].tokenId, loans[_loanId].qty, "");
        }

        totalActiveLoans -= 1;
        delete loans[_loanId];
        loanIdStatus[_loanId] = false;
        loanRepaidOrLiquidated[_loanId] = true;

        emit LoanOverdued(_loanId, loans[_loanId].nftAddress, loans[_loanId].tokenId);
        
        return true;
    }

    function calculateInterest(uint256 amount, uint256 repaymentAmount, uint256 timeDiff, uint256 loanDuration, uint256 interestRate) internal pure returns(uint256) {
        uint256 interestForDuration = amount *  interestRate / 1000;
        uint256 interestForCurrent = interestForDuration * timeDiff / loanDuration;
        if((amount + interestForCurrent) >= repaymentAmount) {
            uint256 lendingInterest = repaymentAmount - amount;
            return lendingInterest;
        }
        return interestForCurrent;
    }

    function getInterest(uint256 _loanId) external view returns(uint256) {
        uint256 timeDiff = block.timestamp - loans[_loanId].loanStartTime;
        uint256 interestDue = calculateInterest(loans[_loanId].loanPrincipalAmount, loans[_loanId].loanRepaymentAmount, timeDiff, loans[_loanId].loanDuration, loans[_loanId].loanInterestForDuration);
        uint256 amount = loans[_loanId].loanPrincipalAmount + interestDue;
        return amount;
    }

    function setBuyerFee(uint256 _buyerFee) external onlyOwner returns(bool) {
        require(_buyerFee >= 0, "Fee must be greater than zero");
        buyerFee = _buyerFee;
        return true;
    }

    function setSellerFee(uint256 _sellerFee) external onlyOwner returns(bool) {
        require(_sellerFee >= 0, "Fee must be greater than zero");
        sellerFee = _sellerFee;
        return true;
    }

    function getUserDetails(uint256 _loanId) external view returns(LoanDetail memory) {
        return loans[_loanId];
    }

    function onERC721Received( address, address, uint256, bytes calldata /*data*/) external pure returns(bytes4) {
        return _ERC721_RECEIVED;
    }
    
    function onERC1155Received( address /*operator*/, address /*from*/, uint256 /*id*/, uint256 /*value*/, bytes calldata /*data*/ ) external pure returns(bytes4) {
        return bytes4(keccak256("onERC1155Received(address,address,uint256,uint256,bytes)"));
    }

}