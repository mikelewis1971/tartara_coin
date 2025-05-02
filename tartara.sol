// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*******************************************************************************************
 *   TartaraCoin (TART) – FINAL USDC-BACKED BUILD (VERIFIED)                              *
 *   ------------------------------------------------------------------------------------- *
 *   - Indivisible ERC-20 (0 decimals)                                                    *
 *   - Dynamic mint price and burn/sell taxes based on divergence between crypto/fiat     *
 *   - Backed 1:1 by Polygon-USDC (6 decimals), no ETH involved                           *
 *   - Architect fee: 8% on mint, 0.08% on exits                                          *
 *   - Kill-switch tied to burnable ConsensusCoin (TKILL)                                 *
 *       - Contract: 0x501cbA7B8a30D7cF319F90537a12ce9C7B8FC105                            *
 *       - Consensus name: "TartarLocker"                                                 *
 *   - Refund function available post-shutdown                                            *
 *   - One free token minted at deploy to architect                                       *
 *******************************************************************************************/

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";

interface IConsensusCoin {
    function hasConsensus(string calldata) external view returns (bool);
}

contract TartaraCoin is ERC20, AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE  = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    IERC20 public constant USDC = IERC20(0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174); // Polygon-USDC
    address public immutable ARCHITECT;

    address public constant CONSENSUS = 0x501cbA7B8a30D7cF319F90537a12ce9C7B8FC105;
    string  public constant CONSENSUS_NAME = "TartarLocker";

    address private constant PAIR_ETH_BTC   = 0xdc9232e2Df177D7a12FdFf6eCBaB114E2231198D;
    address private constant PAIR_PAXG_ETH  = 0x2771B1E532a2c1D82EebACa41eEc59eF7333cCc3;
    address private constant PAIR_JEUR_USDC = 0x718B6d4E59849916cA7C2525cE81E5F95b002Fa2;
    address private constant PAIR_JJPY_USDC = 0xA1Acf2FEE3eE4F6cE219f79b3a6B715F827c7F5C;

    uint32 private constant W_ETH_BTC   = 2 days;
    uint32 private constant W_PAXG_ETH  = 5 days;
    uint32 private constant W_JEUR_USDC = 3 days;
    uint32 private constant W_JJPY_USDC = 3 days;

    uint256 private constant BASE_PRICE_USD = 2.50e6; // USDC 6-decimals
    uint256 private constant MULTIPLIER     = 3;
    uint256 private constant MIN_BURN_TAX   = 5e16;
    uint256 private constant MAX_BURN_TAX   = 50e16;
    uint256 private constant MAX_SELL_TAX   = 60e16;
    uint256 private constant ARCH_MINT_BPS  = 800;  // 8%
    uint256 private constant ARCH_EXIT_BPS  = 8;    // 0.08%

    struct Oracle {
        IUniswapV2Pair pair;
        uint32 period;
        uint256 lastCumulative;
        uint32 lastTs;
        uint256 avg;
    }
    Oracle[4] public oracles;

    bool public permanentlyShutDown;
    mapping(address => uint256) public pendingFees;

    modifier live() { require(!permanentlyShutDown, "TART: shut"); _; }
    modifier idxOK(uint8 i){ require(i<4,"idx"); _; }

    constructor(address architect) ERC20("Tartara Coin","TART") {
        require(architect!=address(0),"arch 0");
        ARCHITECT = architect;

        _grantRole(DEFAULT_ADMIN_ROLE,msg.sender);
        _grantRole(ADMIN_ROLE,msg.sender);
        _grantRole(KEEPER_ROLE,msg.sender);
        _grantRole(PAUSER_ROLE,msg.sender);

        _initO(0,PAIR_ETH_BTC,  W_ETH_BTC);
        _initO(1,PAIR_PAXG_ETH, W_PAXG_ETH);
        _initO(2,PAIR_JEUR_USDC,W_JEUR_USDC);
        _initO(3,PAIR_JJPY_USDC,W_JJPY_USDC);

        _mint(architect, 1); // Mint exactly one free token to the architect
    }

    function _initO(uint8 i,address p,uint32 w) internal {
        Oracle storage o=oracles[i];
        o.pair=IUniswapV2Pair(p); o.period=w;
        (uint112 r0,uint112 r1,uint32 ts)=o.pair.getReserves();
        require(r0>0&&r1>0,"liq");
        o.lastCumulative=o.pair.price0CumulativeLast();
        o.lastTs=ts;
        o.avg=(uint256(r1)<<112)/r0;
    }

    function updateTWAP(uint8 i) public idxOK(i) live whenNotPaused {
        Oracle storage o=oracles[i];
        (, , uint32 ts)=o.pair.getReserves();
        uint32 dt=ts-o.lastTs;
        require(dt>=o.period,"window");
        uint256 cum=o.pair.price0CumulativeLast();
        o.avg=(cum-o.lastCumulative)/dt;
        o.lastCumulative=cum; o.lastTs=ts;
    }

    function updateAll() external onlyRole(KEEPER_ROLE) live {
        for(uint8 i;i<4;i++) { try this.updateTWAP(i) {} catch {} }
    }

    function _divergence() internal view returns(uint256){
        uint256 crypto=(oracles[0].avg+oracles[1].avg)/2;
        uint256 fiat  =(oracles[2].avg+oracles[3].avg)/2;
        return crypto>fiat?crypto-fiat:fiat-crypto;
    }

    function burnTax() public view returns(uint256){
        uint256 raw=(_divergence()>>112);
        if(raw<MIN_BURN_TAX) return MIN_BURN_TAX;
        if(raw>MAX_BURN_TAX) return MAX_BURN_TAX;
        return raw*1e16;
    }

    function sellTax() public view returns(uint256){ return MAX_SELL_TAX - burnTax(); }

    function mintPrice() public view returns(uint256){
        return BASE_PRICE_USD * burnTax() / 1e18 * MULTIPLIER;
    }

    function mint(uint256 amt) external live whenNotPaused nonReentrant {
        require(amt>0,"0 mint");
        uint256 cost= mintPrice()*amt;
        USDC.safeTransferFrom(msg.sender,address(this),cost);
        uint256 fee = cost*ARCH_MINT_BPS/10_000;
        pendingFees[ARCHITECT]+=fee;
        _mint(msg.sender,amt);
    }

    function _payout(uint256 amt,uint256 tax) internal returns(uint256){
        uint256 R = USDC.balanceOf(address(this))*1e18/totalSupply();
        uint256 gross = R*(1e18-tax)/1e18*amt/1e18;
        uint256 fee   = gross*ARCH_EXIT_BPS/10_000;
        pendingFees[ARCHITECT]+=fee;
        return gross-fee;
    }

    function burn(uint256 amt) external live whenNotPaused nonReentrant {
        require(balanceOf(msg.sender)>=amt&&amt>0,"bad burn");
        uint256 pay = _payout(amt,burnTax());
        _burn(msg.sender,amt);
        USDC.safeTransfer(msg.sender,pay/1e12);
    }

    function sell(uint256 amt) external live whenNotPaused nonReentrant {
        require(balanceOf(msg.sender)>=amt&&amt>0,"bad sell");
        uint256 pay = _payout(amt,sellTax());
        _burn(msg.sender,amt);
        USDC.safeTransfer(msg.sender,pay/1e12);
    }

    function withdrawFees() external onlyRole(ADMIN_ROLE) nonReentrant {
        uint256 amt=pendingFees[ARCHITECT];
        require(amt>0,"no fees");
        pendingFees[ARCHITECT]=0;
        USDC.safeTransfer(ARCHITECT,amt/1e12);
    }

    function shutdown() external live {
        require(IConsensusCoin(CONSENSUS).hasConsensus(CONSENSUS_NAME),"consensus false");
        permanentlyShutDown=true;
        _pause();
    }

    function claimRefund() external nonReentrant {
        require(permanentlyShutDown,"not shut");
        uint256 bal=balanceOf(msg.sender);
        require(bal>0,"no TART");
        uint256 R=USDC.balanceOf(address(this))*1e18/totalSupply();
        uint256 pay=R*bal/1e18;
        _burn(msg.sender,bal);
        USDC.safeTransfer(msg.sender,pay/1e12);
    }

    function pause()   external onlyRole(PAUSER_ROLE) live { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) live { _unpause(); }

    function decimals() public pure override returns(uint8){ return 0; }
    function supportsInterface(bytes4 id) public view override(ERC20,AccessControl) returns(bool){
        return super.supportsInterface(id);
    }
}
