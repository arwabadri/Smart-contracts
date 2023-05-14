pragma solidity 0.8.12;
// Copyright BigchainDB GmbH and Ocean Protocol contributors
// SPDX-License-Identifier: (Apache-2.0 AND CC-BY-4.0)
// Code is Apache-2.0 and docs are CC-BY-4.0

import "../interfaces/IERC721Template.sol";
import "../interfaces/IERC20Template.sol";
import "../interfaces/IFactoryRouter.sol";
import "../interfaces/IFixedRateExchange.sol";
import "../interfaces/IDispenser.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "../utils/ERC20Roles.sol";

/**
 * @title DatatokenTemplate
 *
 * @dev ERC20Template3 is an ERC20 compliant token template
 *      Used by the factory contract as a bytecode reference to
 *      deploy new Datatokens.
 * IMPORTANT CHANGES:
 *  - creation of pools/dispensers is not allowed
 *  - creation of additional fixed rates is not allowed (only one can be created)
 */
contract ERC20Template3 is
    ERC20("test", "testSymbol"),
    ERC20Roles,
    ERC20Burnable,
    ReentrancyGuard
{
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    string private _name;
    string private _symbol;
    uint256 private _cap;
    uint8 private constant _decimals = 18;
    bool private initialized = false;
    address private _erc721Address;
    address private paymentCollector;
    address private publishMarketFeeAddress;
    address private publishMarketFeeToken;
    uint256 private publishMarketFeeAmount;
    uint256 private rate = 0;
    uint256 public constant BASE = 1e18;

    // -------------------------- PREDICTOOR --------------------------
    enum Status {
        Pending,
        Paying,
        Canceled
    }
    event PredictionSubmitted(
        address indexed predictoor,
        uint256 indexed slot,
        uint256 stake
    );
    event PredictionPayout(
        address indexed predictoor,
        uint256 indexed slot,
        uint256 stake,
        uint256 payout,
        bool predictedValue,
        bool trueValue,
        uint256 aggregatedPredictedValue,
        Status status
    );
    event NewSubscription(
        address indexed user,
        uint256 expires,
        uint256 blocknum
    );
    event TruevalSubmitted(
        uint256 indexed slot,
        bool trueValue,
        Status status
    );
    struct Prediction {
        bool predictedValue;
        uint256 stake;
        address predictoor;
        bool paid;
    }
    struct Subscription {
        address user;
        uint256 expires;
    }

    event SettingChanged(
        uint256 blocksPerEpoch,
        uint256 blocksPerSubscription,
        uint256 trueValueSubmitTimeoutBlock,
        address stakeToken
    );
    
    event RevenueAdded(
        uint256 totalAmount,
        uint256 slot,
        uint256 amountPerEpoch,
        uint256 numEpochs,
        uint256 blocksPerEpoch
    );

    // All mappings below are using slot as key.  
    // Whenever we have functions that take block as argumens, we rail it to slot automaticly
    mapping(uint256 => mapping(address => Prediction)) private predictions; // id to prediction object
    mapping(uint256 => uint256) private aggregatedPredictedValuesNumer;
    mapping(uint256 => uint256) private aggregatedPredictedValuesDenom;
    mapping(uint256 => bool) public trueValues; // true values submited by owner
    mapping(uint256 => Status) public epochStatus; // status of each epoch
    mapping(uint256 => uint256) private subscriptionRevenueAtBlock; //income registred
    mapping(address => Subscription) public subscriptions; // valid subscription per user
    uint256 public blocksPerEpoch;
    address public stakeToken;
    uint256 public blocksPerSubscription;
    uint256 public trueValSubmitTimeoutBlock;
    bool public paused = false;
    // -------------------------- PREDICTOOR --------------------------

    // EIP 2612 SUPPORT
    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH =
        0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;

    mapping(address => uint256) public nonces;
    address public router;

    struct fixedRate {
        address contractAddress;
        bytes32 id;
    }
    fixedRate[] fixedRateExchanges;
    address[] dispensers;

    // this structure is here only for compatibility reasons with other datatoken templates
    // it's not validated or used anywhere in the code, except as unused argument to startOrder function
    struct providerFee {
        address providerFeeAddress;
        address providerFeeToken; // address of the token
        uint256 providerFeeAmount; // amount to be transfered to provider
        uint8 v; // v of provider signed message
        bytes32 r; // r of provider signed message
        bytes32 s; // s of provider signed message
        uint256 validUntil; //validity expresses in unix timestamp
        bytes providerData; //data encoded by provider
    }

    struct consumeMarketFee {
        address consumeMarketFeeAddress;
        address consumeMarketFeeToken; // address of the token marketplace wants to add fee on top
        uint256 consumeMarketFeeAmount; // amount to be transfered to marketFeeCollector
    }

    event OrderStarted(
        address indexed consumer,
        address payer,
        uint256 amount,
        uint256 serviceIndex,
        uint256 timestamp,
        address indexed publishMarketAddress,
        uint256 blockNumber
    );

    // emited for every order
    event PublishMarketFee(
        address indexed PublishMarketFeeAddress,
        address indexed PublishMarketFeeToken,
        uint256 PublishMarketFeeAmount
    );

    // emited for every order
    event ConsumeMarketFee(
        address indexed consumeMarketFeeAddress,
        address indexed consumeMarketFeeToken,
        uint256 consumeMarketFeeAmount
    );

    event PublishMarketFeeChanged(
        address caller,
        address PublishMarketFeeAddress,
        address PublishMarketFeeToken,
        uint256 PublishMarketFeeAmount
    );

    event MinterProposed(address currentMinter, address newMinter);

    event MinterApproved(address currentMinter, address newMinter);

    event NewFixedRate(
        bytes32 exchangeId,
        address indexed owner,
        address exchangeContract,
        address indexed baseToken
    );
    event NewDispenser(address dispenserContract);

    modifier onlyNotInitialized() {
        require(
            !initialized,
            "ERC20Template: token instance already initialized"
        );
        _;
    }
    modifier onlyNFTOwner() {
        require(
            msg.sender == IERC721Template(_erc721Address).ownerOf(1),
            "ERC20Template: not NFTOwner"
        );
        _;
    }

    modifier onlyPublishingMarketFeeAddress() {
        require(
            msg.sender == publishMarketFeeAddress,
            "ERC20Template: not publishMarketFeeAddress"
        );
        _;
    }

    modifier onlyERC20Deployer() {
        require(
            IERC721Template(_erc721Address)
                .getPermissions(msg.sender)
                .deployERC20 ||
                IERC721Template(_erc721Address).ownerOf(1) == msg.sender,
            "ERC20Template: NOT DEPLOYER ROLE"
        );
        _;
    }

    
    /**
     * @dev initialize
     *      Called prior contract initialization (e.g creating new Datatoken instance)
     *      Calls private _initialize function. Only if contract is not initialized.
     * @param strings_ refers to an array of strings
     *                      [0] = name token
     *                      [1] = symbol
     * @param addresses_ refers to an array of addresses passed by user
     *                     [0]  = minter account who can mint datatokens (can have multiple minters)
     *                     [1]  = paymentCollector initial paymentCollector for this DT
     *                     [2]  = publishing Market Address
     *                     [3]  = publishing Market Fee Token
     *                     [4]  = predictoor stake token
     * @param factoryAddresses_ refers to an array of addresses passed by the factory
     *                     [0]  = erc721Address
     *                     [1]  = router address
     *
     * @param uints_  refers to an array of uints
     *                     [0] = cap_ the total ERC20 cap
     *                     [1] = publishing Market Fee Amount
     *                     [2] = s_per_block,
     *                     [3] = s_per_epoch,
     *                     [4] = s_per_subscription,
     * @param bytes_  refers to an array of bytes
     *                     Currently not used, usefull for future templates
     */
    function initialize(
        string[] calldata strings_,
        address[] calldata addresses_,
        address[] calldata factoryAddresses_,
        uint256[] calldata uints_,
        bytes[] calldata bytes_
    ) external onlyNotInitialized returns (bool) {
        return
            _initialize(
                strings_,
                addresses_,
                factoryAddresses_,
                uints_,
                bytes_
            );
    }

    /**
     * @dev _initialize
     *      Private function called on contract initialization.
     * @param strings_ refers to an array of strings
     *                      [0] = name token
     *                      [1] = symbol
     * @param addresses_ refers to an array of addresses passed by user
     *                     [0]  = minter account who can mint datatokens (can have multiple minters)
     *                     [1]  = paymentCollector initial paymentCollector for this DT
     *                     [2]  = publishing Market Address
     *                     [3]  = publishing Market Fee Token
     *                     [4]  = predictoor stake token
     * @param factoryAddresses_ refers to an array of addresses passed by the factory
     *                     [0]  = erc721Address
     *                     [1]  = router address
     *
     * @param uints_  refers to an array of uints
     *                     [0] = cap_ the total ERC20 cap
     *                     [1] = publishing Market Fee
     *                     [2] = s_per_block,
     *                     [3] = s_per_epoch,
     *                     [4] = s_per_subscription,
     * param bytes_  refers to an array of bytes
     *                     Currently not used, usefull for future templates
     */
    function _initialize(
        string[] memory strings_,
        address[] memory addresses_,
        address[] memory factoryAddresses_,
        uint256[] memory uints_,
        bytes[] memory
    ) private returns (bool) {
        address erc721Address = factoryAddresses_[0];
        router = factoryAddresses_[1];
        require(
            erc721Address != address(0),
            "ERC20Template: Invalid minter,  zero address"
        );

        require(
            router != address(0),
            "ERC20Template: Invalid router, zero address"
        );

        require(uints_[0] != 0, "DatatokenTemplate: Invalid cap value");
        _cap = uints_[0];
        _name = strings_[0];
        _symbol = strings_[1];
        _erc721Address = erc721Address;

        initialized = true;
        // set payment collector to this contract, so we can get the $$$
        _setPaymentCollector(address(this));

        publishMarketFeeAddress = addresses_[2];
        publishMarketFeeToken = addresses_[3];
        publishMarketFeeAmount = uints_[1];
        emit PublishMarketFeeChanged(
            msg.sender,
            publishMarketFeeAddress,
            publishMarketFeeToken,
            publishMarketFeeAmount
        );
        uint256 chainId;
        assembly {
            chainId := chainid()
        }
        /*DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256(bytes(_name)),
                keccak256(bytes("1")), // version, could be any other value
                chainId,
                address(this)
            )
        );
        */

        stakeToken = addresses_[4];
        _updateSeconds(uints_[2], uints_[3], uints_[4], uints_[5]);
        return initialized;
    }

    /**
     * @dev createFixedRate
     *      Creates a new FixedRateExchange setup.
     * @param fixedPriceAddress fixedPriceAddress
     * @param addresses array of addresses [baseToken,owner,marketFeeCollector]
     * @param uints array of uints [baseTokenDecimals,datatokenDecimals, fixedRate, marketFee, withMint]
     * @return exchangeId
     */
    function createFixedRate(
        address fixedPriceAddress,
        address[] memory addresses,
        uint256[] memory uints
    ) external onlyERC20Deployer nonReentrant returns (bytes32 exchangeId) {
        require(fixedRateExchanges.length == 0, "Fixed rate already present");
        require(
            stakeToken == addresses[0],
            "Cannot create FRE with baseToken!=stakeToken"
        );
        //force FRE allowedSwapper to this contract address. no one else can swap because we need to record the income
        if (uints[4] > 0) _addMinter(fixedPriceAddress);
        exchangeId = IFactoryRouter(router).deployFixedRate(
            fixedPriceAddress,
            addresses,
            uints
        );
        emit NewFixedRate(
            exchangeId,
            addresses[1],
            fixedPriceAddress,
            addresses[0]
        );
        fixedRateExchanges.push(fixedRate(fixedPriceAddress, exchangeId));
        rate = uints[2]; //set rate to be added in add_revenue
    }

    /**
     * @dev mint
     *      Only the minter address can call it.
     *      msg.value should be higher than zero and gt or eq minting fee
     * @param account refers to an address that token is going to be minted to.
     * @param value refers to amount of tokens that is going to be minted.
     */
    function mint(address account, uint256 value) external {
        require(permissions[msg.sender].minter, "ERC20Template: NOT MINTER");
        require(
            totalSupply().add(value) <= _cap,
            "DatatokenTemplate: cap exceeded"
        );
        _mint(account, value);
    }

    /**
     * @dev startOrder
     *      called by payer or consumer prior ordering a service consume on a marketplace.
     *      Requires previous approval of consumeFeeToken and publishMarketFeeToken
     * @param consumer is the consumer address (payer could be different address)
     * @param serviceIndex service index in the metadata
     * @param _providerFee provider fee
     * @param _consumeMarketFee consume market fee
     */
    function startOrder(
        address consumer,
        uint256 serviceIndex,
        providerFee calldata _providerFee,
        consumeMarketFee calldata _consumeMarketFee
    ) public nonReentrant{
        uint256 amount = 1e18; // we always pay 1 DT. No more, no less
        require(
            balanceOf(msg.sender) >= amount,
            "Not enough datatokens to start Order"
        );
        emit OrderStarted(
            consumer,
            msg.sender,
            amount,
            serviceIndex,
            block.timestamp,
            publishMarketFeeAddress,
            block.number
        );
        // publishMarketFee
        // Requires approval for the publishMarketFeeToken of publishMarketFeeAmount
        // skip fee if amount == 0 or feeToken == 0x0 address or feeAddress == 0x0 address
        if (
            publishMarketFeeAmount > 0 &&
            publishMarketFeeToken != address(0) &&
            publishMarketFeeAddress != address(0)
        ) {
            _pullUnderlying(
                publishMarketFeeToken,
                msg.sender,
                publishMarketFeeAddress,
                publishMarketFeeAmount
            );
            emit PublishMarketFee(
                publishMarketFeeAddress,
                publishMarketFeeToken,
                publishMarketFeeAmount
            );
        }

        // consumeMarketFee
        // Requires approval for the FeeToken
        // skip fee if amount == 0 or feeToken == 0x0 address or feeAddress == 0x0 address
        if (
            _consumeMarketFee.consumeMarketFeeAmount > 0 &&
            _consumeMarketFee.consumeMarketFeeToken != address(0) &&
            _consumeMarketFee.consumeMarketFeeAddress != address(0)
        ) {
            _pullUnderlying(
                _consumeMarketFee.consumeMarketFeeToken,
                msg.sender,
                _consumeMarketFee.consumeMarketFeeAddress,
                _consumeMarketFee.consumeMarketFeeAmount
            );
            emit ConsumeMarketFee(
                _consumeMarketFee.consumeMarketFeeAddress,
                _consumeMarketFee.consumeMarketFeeToken,
                _consumeMarketFee.consumeMarketFeeAmount
            );
        }
        //fetch bastetokens from fre
        if(fixedRateExchanges.length>0){
            IFixedRateExchange fre = IFixedRateExchange(
                fixedRateExchanges[0].contractAddress
            );
            (, , , , , , , , , , uint256 btBalance, ) = fre.getExchange(
            fixedRateExchanges[0].id
            );
            if (btBalance > 0) {
                fre.collectBT(fixedRateExchanges[0].id, btBalance);
            }
        }
        Subscription memory sub = Subscription(
            consumer,
            block.number + blocksPerSubscription
        );
        subscriptions[consumer] = sub;
        emit NewSubscription(consumer, block.number + blocksPerSubscription,block.number);
        //record income
        add_revenue(block.number, rate);

        burn(amount);
    }

    /**
     * @dev removeMinter
     *      Only ERC20Deployer (at 721 level) can update.
     *      There can be multiple minters
     * @param _minter minter address to remove
     */

    function removeMinter(address _minter) external onlyERC20Deployer {
        _removeMinter(_minter);
    }

    /**
     * @dev setData
     *      Only ERC20Deployer (at 721 level) can call it.
     *      This function allows to store data with a preset key (keccak256(ERC20Address)) into NFT 725 Store
     * @param _value data to be set with this key
     */

    function setData(bytes calldata _value) external onlyERC20Deployer {
        bytes32 key = keccak256(abi.encodePacked(address(this)));
        IERC721Template(_erc721Address).setDataERC20(key, _value);
    }

    /**
     * @dev cleanPermissions()
     *      Only NFT Owner (at 721 level) can call it.
     *      This function allows to remove all minters, feeManagers and reset the paymentCollector
     *
     */

    function cleanPermissions() external onlyNFTOwner {
        _internalCleanPermissions();
    }

    /**
     * @dev cleanFrom721()
     *      OnlyNFT(721) Contract can call it.
     *      This function allows to remove all minters, feeManagers and reset the paymentCollector
     *       This function is used when transferring an NFT to a new owner,
     * so that permissions at ERC20level (minter,feeManager,paymentCollector) can be reset.
     *
     */
    function cleanFrom721() external {
        require(
            msg.sender == _erc721Address,
            "ERC20Template: NOT 721 Contract"
        );
        _internalCleanPermissions();
    }

    function _internalCleanPermissions() internal {
        uint256 totalLen = fixedRateExchanges.length + dispensers.length;
        uint256 curentLen = 0;
        address[] memory previousMinters = new address[](totalLen);
        // loop though fixedrates, empty and preserve the minter rols if exists
        uint256 i;
        for (i = 0; i < fixedRateExchanges.length; i++) {
            IFixedRateExchange fre = IFixedRateExchange(
                fixedRateExchanges[i].contractAddress
            );
            (
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                ,
                uint256 dtBalance,
                uint256 btBalance,
                bool withMint
            ) = fre.getExchange(fixedRateExchanges[i].id);
            if (btBalance > 0)
                fre.collectBT(fixedRateExchanges[i].id, btBalance);
            if (dtBalance > 0)
                fre.collectDT(fixedRateExchanges[i].id, dtBalance);
            // add it to the list of minters
            if (
                isMinter(fixedRateExchanges[i].contractAddress) &&
                withMint == true
            ) {
                previousMinters[curentLen] = fixedRateExchanges[i]
                    .contractAddress;
                curentLen++;
            }
        }
        // clear all permisions
        _cleanPermissions();
        // set collector to 0
        paymentCollector = address(0);
        // add existing minter roles for fixedrate & dispensers
        for (i = 0; i < curentLen; i++) {
            _addMinter(previousMinters[i]);
        }
    }

    /**
     * @dev setPaymentCollector
     *      Only feeManager can call it
     *      This function allows to set a newPaymentCollector (receives DT when consuming)
            If not set the paymentCollector is the NFT Owner
     * @param _newPaymentCollector new fee collector 
     */

    function setPaymentCollector(address _newPaymentCollector) external {
        // does nothing for this template, paymentCollector is always address(this)
    }

    /**
     * @dev _setPaymentCollector
     * @param _newPaymentCollector new fee collector
     */

    function _setPaymentCollector(address _newPaymentCollector) internal {
        paymentCollector = _newPaymentCollector;
    }

    /**
     * @dev getPublishingMarketFee
     *      Get publishingMarket Fee
     *      This function allows to get the current fee set by the publishing market
     */
    function getPublishingMarketFee()
        external
        view
        returns (address, address, uint256)
    {
        return (
            publishMarketFeeAddress,
            publishMarketFeeToken,
            publishMarketFeeAmount
        );
    }

    /**
     * @dev setPublishingMarketFee
     *      Only publishMarketFeeAddress can call it
     *      This function allows to set the fee required by the publisherMarket
     * @param _publishMarketFeeAddress  new _publishMarketFeeAddress
     * @param _publishMarketFeeToken new _publishMarketFeeToken
     * @param _publishMarketFeeAmount new fee amount
     */
    function setPublishingMarketFee(
        address _publishMarketFeeAddress,
        address _publishMarketFeeToken,
        uint256 _publishMarketFeeAmount
    ) external onlyPublishingMarketFeeAddress {
        require(
            _publishMarketFeeAddress != address(0),
            "Invalid _publishMarketFeeAddress address"
        );
        require(
            _publishMarketFeeToken != address(0),
            "Invalid _publishMarketFeeToken address"
        );
        publishMarketFeeAddress = _publishMarketFeeAddress;
        publishMarketFeeToken = _publishMarketFeeToken;
        publishMarketFeeAmount = _publishMarketFeeAmount;
        emit PublishMarketFeeChanged(
            msg.sender,
            _publishMarketFeeAddress,
            _publishMarketFeeToken,
            _publishMarketFeeAmount
        );
    }

    /**
     * @dev getId
     *      Return template id in case we need different ABIs.
     *      If you construct your own template, please make sure to change the hardcoded value
     */
    function getId() public pure returns (uint8) {
        return 3;
    }

    /**
     * @dev name
     *      It returns the token name.
     * @return Datatoken name.
     */
    function name() public view override returns (string memory) {
        return _name;
    }

    /**
     * @dev symbol
     *      It returns the token symbol.
     * @return Datatoken symbol.
     */
    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /**
     * @dev getERC721Address
     *      It returns the parent ERC721
     * @return ERC721 address.
     */
    function getERC721Address() public view returns (address) {
        return _erc721Address;
    }

    /**
     * @dev decimals
     *      It returns the token decimals.
     *      how many supported decimal points
     * @return Datatoken decimals.
     */
    function decimals() public pure override returns (uint8) {
        return _decimals;
    }

    /**
     * @dev cap
     *      it returns the capital.
     * @return Datatoken cap.
     */
    function cap() external view returns (uint256) {
        return _cap;
    }

    /**
     * @dev isInitialized
     *      It checks whether the contract is initialized.
     * @return true if the contract is initialized.
     */

    function isInitialized() external view returns (bool) {
        return initialized;
    }

    /**
     * @dev getPaymentCollector
     *      It returns the current paymentCollector
     * @return paymentCollector address
     */

    function getPaymentCollector() public view returns (address) {
        return address(this);
    }

    /**
     * @dev fallback function
     *      this is a default fallback function in which receives
     *      the collected ether.
     */
    fallback() external payable {}

    /**
     * @dev receive function
     *      this is a default receive function in which receives
     *      the collected ether.
     */
    receive() external payable {}

    /**
     * @dev withdrawETH
     *      transfers all the accumlated ether the collector account
     */
    function withdrawETH() external payable {
        payable(getPaymentCollector()).transfer(address(this).balance);
    }

    struct OrderParams {
        address consumer;
        uint256 serviceIndex;
        providerFee _providerFee;
        consumeMarketFee _consumeMarketFee;
    }
    struct FreParams {
        address exchangeContract;
        bytes32 exchangeId;
        uint256 maxBaseTokenAmount;
        uint256 swapMarketFee;
        address marketFeeAddress;
    }

    /**
     * @dev buyFromFre
     *      Buys 1 DT from the FRE
     */
    function buyFromFre(FreParams calldata _freParams) internal {
        // get exchange info
        IFixedRateExchange fre = IFixedRateExchange(
            _freParams.exchangeContract
        );
        (, address datatoken, , address baseToken, , , , , , , , ) = fre
            .getExchange(_freParams.exchangeId);
        require(
            datatoken == address(this),
            "This FixedRate is not providing this DT"
        );
        // get token amounts needed
        (uint256 baseTokenAmount, , , ) = fre.calcBaseInGivenOutDT(
            _freParams.exchangeId,
            1e18, // we always take 1 DT
            _freParams.swapMarketFee
        );
        require(
            baseTokenAmount <= _freParams.maxBaseTokenAmount,
            "FixedRateExchange: Too many base tokens"
        );

        //transfer baseToken to us first
        _pullUnderlying(baseToken, msg.sender, address(this), baseTokenAmount);
        //approve FRE to spend baseTokens
        IERC20(baseToken).safeIncreaseAllowance(
            _freParams.exchangeContract,
            baseTokenAmount
        );
        //buy DT
        fre.buyDT(
            _freParams.exchangeId,
            1e18, // we always take 1 dt
            baseTokenAmount,
            _freParams.marketFeeAddress,
            _freParams.swapMarketFee
        );
        require(
            balanceOf(address(this)) >= 1e18,
            "Unable to buy DT from FixedRate"
        );
        // collect the basetoken from fixedrate and sent it
        (, , , , , , , , , , uint256 btBalance, ) = fre.getExchange(
            _freParams.exchangeId
        );
        if (btBalance > 0) {
            fre.collectBT(_freParams.exchangeId, btBalance);
        }
    }

    /**
     * @dev buyFromFreAndOrder
     *      Buys 1 DT from the FRE and then startsOrder, while burning that DT
     */
    function buyFromFreAndOrder(
        OrderParams calldata _orderParams,
        FreParams calldata _freParams
    ) external nonReentrant {
        //first buy 1.0 DT
        buyFromFre(_freParams);
        //we need the following because startOrder expects msg.sender to have dt
        _transfer(address(this), msg.sender, 1e18);
        //startOrder and burn it
        startOrder(
            _orderParams.consumer,
            _orderParams.serviceIndex,
            _orderParams._providerFee,
            _orderParams._consumeMarketFee
        );
    }

   

    /**
     * @dev isERC20Deployer
     *      returns true if address has deployERC20 role
     */
    function isERC20Deployer(address user) public view returns (bool) {
        return (
            IERC721Template(_erc721Address).getPermissions(user).deployERC20
        );
    }

    /**
     * @dev getFixedRates
     *      Returns the list of fixedRateExchanges created for this datatoken
     */
    function getFixedRates() public view returns (fixedRate[] memory) {
        return (fixedRateExchanges);
    }

    /**
     * @dev getDispensers
     *      Returns the list of dispensers created for this datatoken
    */
    function getDispensers() public view returns (address[] memory) {
        return (dispensers);
    }

    function _pullUnderlying(
        address erc20,
        address from,
        address to,
        uint256 amount
    ) internal {
        uint256 balanceBefore = IERC20(erc20).balanceOf(to);
        IERC20(erc20).safeTransferFrom(from, to, amount);
        require(
            IERC20(erc20).balanceOf(to) >= balanceBefore.add(amount),
            "Transfer amount is too low"
        );
    }

    // ------------ PREDICTOOR ------------
    function isValidSubscription(address user) public view returns (bool) {
        return subscriptions[user].expires <= block.number ? false : true;
    }

    function epoch(uint256 blocknum) public view returns (uint256) {
        return blocknum / blocksPerEpoch;
    }

    function curEpoch() public view returns (uint256) {
        return epoch(block.number);
    }

    function railBlocknumToSlot(
        uint256 blocknum
    ) public view returns (uint256) {
        uint256 rounded = blocknum / blocksPerEpoch;
        return (rounded * blocksPerEpoch);
    }   

    function blocknumIsOnSlot(
        uint256 blocknum
    ) public view returns (bool) {
        // a slot == beginning/end of an epoch
        return blocknum == railBlocknumToSlot(blocknum);
    }

    function soonestBlockToPredict(uint256 prediction_block) public view returns (uint256) {
        /*
        Epoch i: predictoors submit predictedValue for the beginning of epoch i+2. 
        Predval is: "does trueValue go UP or DOWN between the start of epoch i+1 and the start of epoch i+2?"
        Once epoch i ends, predictoors cannot submit predictedValues for epoch i+2
        */
        return(railBlocknumToSlot(prediction_block)+ blocksPerEpoch * 2);
    }

    function submittedPredval(
        uint256 blocknum,
        address predictoor
    ) public view returns (bool) {
        uint256 slot = railBlocknumToSlot(blocknum);
        return predictions[slot][predictoor].predictoor != address(0);
    }

    function getAggPredval(
        uint256 blocknum
    ) public view returns (uint256, uint256) {
        require(isValidSubscription(msg.sender), "No subscription");
        uint256 slot = railBlocknumToSlot(blocknum);
        return (aggregatedPredictedValuesNumer[slot], aggregatedPredictedValuesDenom[slot]);
    }

    function getSubscriptionRevenueAtBlock(
        uint256 blocknum
    ) public view returns (uint256) {
        uint256 slot = railBlocknumToSlot(blocknum);
        return (subscriptionRevenueAtBlock[slot]);
    }

    function getPrediction(
        uint256 blocknum,
        address predictoor
    )
        public
        view
        returns (Prediction memory prediction)
    {
        //allow predictoors to see their own submissions
        require(msg.sender == predictoor || blocknum < block.number, "you shall not pass");
        uint256 slot = railBlocknumToSlot(blocknum);
        prediction = predictions[slot][predictoor];
    }

    // ----------------------- MUTATING FUNCTIONS -----------------------

    function submitPredval(
        bool predictedValue,
        uint256 stake,
        uint256 blocknum
    ) external {
        require(paused == false, "paused");
        uint256 slot = railBlocknumToSlot(blocknum);
        require(slot >= soonestBlockToPredict(block.number), "too late to submit");
        require(!submittedPredval(slot, msg.sender), "already submitted");
        
        predictions[slot][msg.sender] = Prediction(
            predictedValue,
            stake,
            msg.sender,
            false
        );

        // update agg_predictedValues
        aggregatedPredictedValuesNumer[slot] += stake * (predictedValue ? 1 : 0);
        aggregatedPredictedValuesDenom[slot] += stake;

        emit PredictionSubmitted(msg.sender, slot, stake);
        // safe transfer stake
        IERC20(stakeToken).safeTransferFrom(msg.sender, address(this), stake);
    }

    function payoutMultiple(
        uint256[] calldata blocknums,
        address predictoor_addr
    ) external {
      for (uint i = 0; i < blocknums.length; i++) {
        payout(blocknums[i], predictoor_addr);
      }
    }

    function payout(
        uint256 blocknum,
        address predictoor_addr
    ) public nonReentrant {
        require(submittedPredval(blocknum, predictoor_addr), "not submitted");
        uint256 slot = railBlocknumToSlot(blocknum);
        Prediction memory predobj = predictions[slot][predictoor_addr];
        if(predobj.paid) return; // just return if already paid, in order not to break payoutMultiple
        
        // if OPF hasn't submitted trueValue in truval_submit_timeout blocks then cancel round
        if (block.number > slot + trueValSubmitTimeoutBlock && epochStatus[slot]==Status.Pending){
            epochStatus[slot]=Status.Canceled;
        }

        if(epochStatus[slot]==Status.Pending){
            // if Status is Pending, do nothing, just return
            return; 
        }
        uint256 payout_amt = 0;
        predictions[slot][predictoor_addr].paid = true;
        if(epochStatus[slot]==Status.Canceled){
            payout_amt = predobj.stake;
        }
        else{ // Status.Paying
            if(trueValues[slot] == predobj.predictedValue){
                // he got it.
                uint256 swe = trueValues[slot]
                    ? aggregatedPredictedValuesNumer[slot]
                    : aggregatedPredictedValuesDenom[slot] - aggregatedPredictedValuesNumer[slot];
                if(swe > 0) {
                    uint256 revenue=getSubscriptionRevenueAtBlock(slot);
                    payout_amt = predobj.stake * (aggregatedPredictedValuesDenom[slot] + revenue) / swe;
                }
            }
            // else payout_amt is already 0
        }
        emit PredictionPayout(
                    predictoor_addr,
                    slot,
                    predobj.stake,
                    payout_amt,
                    predobj.predictedValue,
                    trueValues[slot],
                    aggregatedPredictedValuesNumer[slot] * 1e18 / aggregatedPredictedValuesDenom[slot],
                    epochStatus[slot]
                );
        if(payout_amt>0)
            IERC20(stakeToken).safeTransfer(predobj.predictoor, payout_amt);
    }

    // ----------------------- ADMIN FUNCTIONS -----------------------
    function redeemUnusedSlotRevenue(uint256 blocknum) external onlyERC20Deployer {
        require(block.number > blocknum);
        uint256 slot = railBlocknumToSlot(blocknum);
        require(aggregatedPredictedValuesDenom[slot] == 0);
        IERC20(stakeToken).safeTransfer(
            msg.sender,
            subscriptionRevenueAtBlock[slot]
        );
    }


    function pausePredictions() external onlyERC20Deployer {
        paused = !paused;
        // TODO - pause FRE as well
    }

    function submitTrueVal(
        uint256 blocknum,
        bool trueValue
    ) external onlyERC20Deployer {
        // TODO, is onlyERC20Deployer the right modifier?
        require(blocknum < block.number, "too early to submit");
        uint256 slot = railBlocknumToSlot(blocknum);
        require(epochStatus[slot]==Status.Pending, "already settled");
        if (block.number > slot + trueValSubmitTimeoutBlock && epochStatus[slot]==Status.Pending){
            epochStatus[slot]=Status.Canceled;
        }
        else{
            trueValues[slot] = trueValue;
            epochStatus[slot] = Status.Paying;
        }
        emit TruevalSubmitted(slot, trueValue,epochStatus[slot]);
    }

    function updateSeconds(
        uint256 s_per_block,
        uint256 s_per_subscription,
        uint256 _truval_submit_timeout
    ) external onlyERC20Deployer {
        _updateSeconds(
            s_per_block,
            0, // can only be set once
            s_per_subscription,
            _truval_submit_timeout
        );
    }

    // ----------------------- INTERNAL FUNCTIONS -----------------------

    function _updateSeconds(
        uint256 s_per_block,
        uint256 s_per_epoch,
        uint256 s_per_subscription,
        uint256 _truval_submit_timeout
    ) internal {
        require(s_per_subscription % s_per_block == 0, "%");
        require(s_per_epoch % s_per_block == 0, "%");

        if (blocksPerEpoch == 0) {
            blocksPerEpoch = s_per_epoch / s_per_block; // immutaable
        }

        blocksPerSubscription = s_per_subscription / s_per_block;
        trueValSubmitTimeoutBlock = _truval_submit_timeout / s_per_block;
        emit SettingChanged(blocksPerEpoch,blocksPerSubscription,trueValSubmitTimeoutBlock,stakeToken);
    }

    function add_revenue(uint256 blocknum, uint256 amount) internal {
        if (amount > 0) {
            uint256 slot = railBlocknumToSlot(blocknum);
            uint256 num_epochs = blocksPerSubscription / blocksPerEpoch;
            if(num_epochs<1)
                num_epochs=1;
            uint256 amt_per_epoch = amount / num_epochs;
            // for loop and add revenue for blocksPerEpoch blocks
            for (uint256 i = 0; i < num_epochs; i++) {
                // TODO FIND A WAY TO ACHIEVE THIS WITHOUT A LOOP
                subscriptionRevenueAtBlock[
                    slot + blocksPerEpoch * (i)
                ] += amt_per_epoch;
            }
            emit RevenueAdded(amount,slot,amt_per_epoch,num_epochs,blocksPerEpoch);
        }
    }
}
