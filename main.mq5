//+------------------------------------------------------------------+
//|                                           HydraPrime_Gold_v1.mq5 |
//|                     HYDRA PRIME: AURUM EDITION                   |
//|       Specialized Logic for XAUUSD (Liquidity & Deep Structure)  |
//+------------------------------------------------------------------+
#property copyright "Hydra Prime Architecture"
#property link      "Internal"
#property version   "1.01 Gold" // Version Bump
#property strict
#property tester_indicator "ATR"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>
#include <Trade\OrderInfo.mqh> // Added for robust order selection

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                     |
//+------------------------------------------------------------------+
enum ENUM_TRAIL_MODE {
   TRAIL_NONE,          // No Trailing
   TRAIL_VOLATILITY,    // Gold Specific: Loose ATR Trail
   TRAIL_BREAKEVEN_ONLY // Secure entry and hold
};

//+------------------------------------------------------------------+
//| INPUT PARAMETERS (TUNED FOR GOLD M5)                             |
//+------------------------------------------------------------------+
input group "=== 1. Gold Setup ==="
input string    InpSymbol1        = "XAUUSD";
input int       InpMagicNum       = 197400;
input double    InpMaxDailyLoss   = 5.0;     // Max Daily Drawdown (%)
input int       InpMaxTotalTrades = 1;       // Sniper mode: 1 trade at a time
input double    InpRisk_Per_Trade = 1.0;     // Risk per trade %

input group "=== 2. Session (GMT) ==="
input int       InpBroker_GMT_Offset = 2;    // Check your broker!
input int       InpStart_Hour        = 8;    // London Open (Critical for Gold)
input int       InpEnd_Hour          = 18;   // NY Lunch Close
input bool      InpTrade_Friday      = false; // Gold often chops on late Friday

input group "=== 3. Deep Structure (Liquidity) ==="
input ENUM_TIMEFRAMES InpTF       = PERIOD_M5;
input double    InpBaseSwing_Dev  = 2.0;           // STIFF deviation to ignore noise
input int       InpVol_Period     = 14;            // Standard ATR
input double    InpOTE_Shallow    = 0.705;         // Entry Start (Deeper than 0.618)
input double    InpOTE_Deep       = 0.886;         // Entry End (The "Sweet Spot")
input int       InpCancel_Bars    = 12;            // Give Gold more time to return

input group "=== 4. Protection & Wick Logic ==="
input double    InpSL_ATR_Mult    = 2.5;           // Wide stop to survive volatility
input double    InpLiquidity_Pad  = 200;           // Points (approx $2.00) extra padding below Low
input double    InpMin_Stop_Dist  = 100;           // Points (Allow $1.00 min stop distance)
input double    InpTP_Risk_Reward = 4.0;           // Target 4R (Realistic for Gold runs)

input group "=== 5. Management ==="
input ENUM_TRAIL_MODE InpTrailMode = TRAIL_VOLATILITY; 
input double          InpTrail_ATR = 3.5;          // Loose trailing (Gold breathes deep)
input bool            InpUse_Partial = true;       // Secure the bag early on Gold
input double          InpSpread_Max  = 400;        // Max Spread in Points ($0.40)

// --- Global Objects ---
CTrade          trade;
CPositionInfo   posInfo;
CAccountInfo    accInfo;
COrderInfo      orderInfo; // Added object

// --- Structures ---
struct CSwingNode {
   double   price;
   datetime time;
   int      type; // 1=High, -1=Low
};

struct CFVG {
   bool     valid;
   double   top;
   double   bottom;
};

struct CState {
   CSwingNode History[30]; 
   int        count;
   int        dir;
   double     lastExtreme;
   datetime   lastExTime;
   datetime   lastCalcBar;
   datetime   LastTradedLegTime;
};

CState          State;
double          dailyStartEquity;
datetime        lastDayCheck;
int             handle_ATR;
ulong           PartialedTickets[]; // Memory for partial closes

// Forward Declarations
double GetATR(int idx);
void   UpdateZigZag(string sym);
void   AnalyzeStructure(string sym);
void   ManageLifecycle(string sym);
bool   ExecuteTrade(string sym, int dir, double entry, double sl, double tp);
double CalculateRobustLots(string sym, double entry, double sl, double riskPct);
bool   IsNewDay();
bool   SpreadOk(string sym);
void   CheckDailyDrawdown();
void   SetRobustFillingMode(string sym);

// Partial Memory Helpers
bool   IsPartialled(ulong ticket);
void   MarkPartialled(ulong ticket);

//+------------------------------------------------------------------+
//| INITIALIZATION                                                   |
//+------------------------------------------------------------------+
int OnInit() {
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetMarginMode();
   trade.SetDeviationInPoints(100); 
   
   if(InpSymbol1 != "") {
      if(!SymbolSelect(InpSymbol1, true)) return INIT_FAILED;
      SetRobustFillingMode(InpSymbol1);
      handle_ATR = iATR(InpSymbol1, InpTF, InpVol_Period);
      if(handle_ATR == INVALID_HANDLE) return INIT_FAILED;
   }

   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   lastDayCheck = TimeCurrent();
   State.lastCalcBar = 0;
   State.count = 0;
   State.LastTradedLegTime = 0;
   ArrayResize(PartialedTickets, 0); // Reset memory on init

   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   IndicatorRelease(handle_ATR);
   ArrayFree(PartialedTickets);
}

//+------------------------------------------------------------------+
//| MAIN LOOP                                                        |
//+------------------------------------------------------------------+
void OnTick() {
   static datetime lastRun = 0;
   datetime now = TimeCurrent();
   
   if(now == lastRun) return; 
   lastRun = now;

   CheckDailyDrawdown(); 

   string sym = InpSymbol1;
   if(sym == "") return;

   // 1. Manage existing trades (Updated)
   ManageLifecycle(sym);
   
   // 2. Scan structure on new bar
   datetime currBar = iTime(sym, InpTF, 0);
   if(currBar > State.lastCalcBar) {
      State.lastCalcBar = currBar;
      UpdateZigZag(sym);
      AnalyzeStructure(sym);
   }

   if(IsNewDay()) dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
}

//+------------------------------------------------------------------+
//| LOGIC: EXECUTION & MANAGEMENT (UPDATED)                          |
//+------------------------------------------------------------------+
void ManageLifecycle(string sym) {
   // A. Clean Pending Orders (FIXED SELECTION LOGIC)
   for(int i = OrdersTotal() - 1; i >= 0; i--) {
      // Use COrderInfo for robust selection
      if(orderInfo.SelectByIndex(i)) {
         if(orderInfo.Symbol() == sym && orderInfo.Magic() == InpMagicNum) {
            datetime setupTime = (datetime)orderInfo.TimeSetup();
            int shift = iBarShift(sym, InpTF, setupTime);
            
            // Delete stale limits
            if(shift > InpCancel_Bars) {
               trade.OrderDelete(orderInfo.Ticket());
            }
         }
      }
   }

   // B. Manage Positions (ADDED PARTIAL MEMORY)
   for(int i = PositionsTotal() - 1; i >= 0; i--) {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != sym || posInfo.Magic() != InpMagicNum) continue;

      ulong ticket = posInfo.Ticket();
      double open  = posInfo.PriceOpen();
      double curr  = posInfo.PriceCurrent();
      double sl    = posInfo.StopLoss();
      double tp    = posInfo.TakeProfit();
      double vol   = posInfo.Volume();
      long type    = posInfo.PositionType();

      double r_dist = MathAbs(open - sl);
      if(r_dist < SymbolInfoDouble(sym, SYMBOL_POINT)) continue; 

      double profit_points = (type == POSITION_TYPE_BUY) ? (curr - open) : (open - curr);
      double r_current = profit_points / r_dist;

      // 1. Partial Close with Memory Check
      if(InpUse_Partial && r_current >= 2.0) {
         // Check Memory: Have we already partialled this specific ticket?
         if(!IsPartialled(ticket)) {
            double minVol = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
            double step   = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
            
            // Ensure we have enough volume to split (at least 2x min)
            if(vol >= minVol * 2.0) { 
               double partVol = MathFloor((vol * 0.5) / step) * step;
               if(partVol >= minVol) {
                  if(trade.PositionClosePartial(ticket, partVol)) {
                     MarkPartialled(ticket); // Remember this action
                     
                     // Move SL to Breakeven + Buffer
                     double buffer = 50 * SymbolInfoDouble(sym, SYMBOL_POINT); 
                     double be = (type == POSITION_TYPE_BUY) ? (open + buffer) : (open - buffer);
                     trade.PositionModify(ticket, be, tp);
                     
                     // Refresh position info after modification before continuing
                     continue; 
                  }
               }
            } else {
               // Volume too small to partial, mark as processed to stop checking
               MarkPartialled(ticket); 
            }
         }
      }

      // 2. Trailing Stop
      if(InpTrailMode == TRAIL_VOLATILITY && r_current >= 1.5) {
         double atr = GetATR(0);
         double trailDist = atr * InpTrail_ATR;
         double new_sl = sl;
         bool modify = false;

         if(type == POSITION_TYPE_BUY) {
            double proposed = curr - trailDist;
            if(proposed > sl && proposed > open) { new_sl = proposed; modify = true; }
         } else {
            double proposed = curr + trailDist;
            if(proposed < sl && proposed < open) { new_sl = proposed; modify = true; }
         }
         
         if(modify) trade.PositionModify(ticket, new_sl, tp);
      }
   }
}

//+------------------------------------------------------------------+
//| PARTIAL MEMORY FUNCTIONS                                         |
//+------------------------------------------------------------------+
bool IsPartialled(ulong ticket) {
   int size = ArraySize(PartialedTickets);
   for(int i=0; i<size; i++) {
      if(PartialedTickets[i] == ticket) return true;
   }
   return false;
}

void MarkPartialled(ulong ticket) {
   if(IsPartialled(ticket)) return;
   int size = ArraySize(PartialedTickets);
   ArrayResize(PartialedTickets, size + 1);
   PartialedTickets[size] = ticket;
}

//+------------------------------------------------------------------+
//| ZIGZAG & STRUCTURE LOGIC                                         |
//+------------------------------------------------------------------+
void UpdateZigZag(string sym) {
   double atr = GetATR(0);
   if(atr == 0) return;

   double dev = InpBaseSwing_Dev * atr;
   
   double high = iHigh(sym, InpTF, 1);
   double low  = iLow(sym, InpTF, 1);
   datetime time = iTime(sym, InpTF, 1);

   if(State.dir == 0) {
      State.lastExtreme = high;
      State.lastExTime = time;
      State.dir = 1;
      return;
   }

   if(State.dir == 1) { // Trend Up
      if(high > State.lastExtreme) {
         State.lastExtreme = high;
         State.lastExTime = time;
      }
      else if(low < State.lastExtreme - dev) {
         AddSwing(State.lastExtreme, State.lastExTime, 1);
         State.dir = -1;
         State.lastExtreme = low;
         State.lastExTime = time;
      }
   }
   else if(State.dir == -1) { // Trend Down
      if(low < State.lastExtreme) {
         State.lastExtreme = low;
         State.lastExTime = time;
      }
      else if(high > State.lastExtreme + dev) {
         AddSwing(State.lastExtreme, State.lastExTime, -1);
         State.dir = 1;
         State.lastExtreme = high;
         State.lastExTime = time;
      }
   }
}

void AddSwing(double price, datetime time, int type) {
   for(int k=29; k>0; k--) State.History[k] = State.History[k-1];
   State.History[0].price = price;
   State.History[0].time = time;
   State.History[0].type = type;
   if(State.count < 30) State.count++;
}

void AnalyzeStructure(string sym) {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int gmt_hour = dt.hour - InpBroker_GMT_Offset;
   if(gmt_hour < 0) gmt_hour += 24;
   
   if(gmt_hour < InpStart_Hour || gmt_hour > InpEnd_Hour) return;
   if(InpTrade_Friday == false && dt.day_of_week == 5) return; 

   if(State.count < 2) return;

   CSwingNode end   = State.History[0];
   CSwingNode start = State.History[1];
   if(start.time == State.LastTradedLegTime) return;

   double atr = GetATR(0);
   double range = MathAbs(end.price - start.price);
   
   if(range < atr * 1.5) return; 

   if(start.type == -1 && end.type == 1) { 
      double oteShallow = end.price - (range * InpOTE_Shallow);
      double oteDeep    = end.price - (range * InpOTE_Deep);
      CFVG fvg = ScanLegForFVG(sym, start.time, end.time, true, atr);

      if(fvg.valid) {
         double zoneTop = MathMin(fvg.top, oteShallow);
         double zoneBot = MathMax(fvg.bottom, oteDeep);
         
         if(zoneTop > zoneBot) {
            double entry = zoneTop; 
            double sl = start.price - (atr * InpSL_ATR_Mult) - (InpLiquidity_Pad * SymbolInfoDouble(sym, SYMBOL_POINT));
            double tp = entry + ((entry - sl) * InpTP_Risk_Reward);
            
            if(ExecuteTrade(sym, 1, entry, sl, tp)) State.LastTradedLegTime = start.time;
         }
      }
   }

   if(start.type == 1 && end.type == -1) { 
      double oteShallow = end.price + (range * InpOTE_Shallow);
      double oteDeep    = end.price + (range * InpOTE_Deep);
      CFVG fvg = ScanLegForFVG(sym, start.time, end.time, false, atr);

      if(fvg.valid) {
         double zoneTop = MathMin(fvg.top, oteDeep);
         double zoneBot = MathMax(fvg.bottom, oteShallow);
         
         if(zoneTop > zoneBot) {
            double entry = zoneBot; 
            double sl = start.price + (atr * InpSL_ATR_Mult) + (InpLiquidity_Pad * SymbolInfoDouble(sym, SYMBOL_POINT));
            double tp = entry - ((sl - entry) * InpTP_Risk_Reward);
            
            if(ExecuteTrade(sym, -1, entry, sl, tp)) State.LastTradedLegTime = start.time;
         }
      }
   }
}

CFVG ScanLegForFVG(string sym, datetime tStart, datetime tEnd, bool bullish, double atr) {
   CFVG best; best.valid = false; best.top = 0; best.bottom = 0;
   
   int idxA = iBarShift(sym, InpTF, tStart);
   int idxB = iBarShift(sym, InpTF, tEnd);
   int startIdx = MathMax(idxA, idxB);
   int endIdx   = MathMin(idxA, idxB);
   int total    = iBars(sym, InpTF);

   double minGap = atr * 0.30; 

   for(int i = startIdx - 1; i > endIdx + 1; i--) {
      if(i < 0 || i+2 >= total) continue;
      
      if(bullish) {
         double rightLow = iLow(sym, InpTF, i); 
         double leftHigh = iHigh(sym, InpTF, i+2);
         if(rightLow > leftHigh && (rightLow - leftHigh) > minGap) {
            best.valid = true; best.top = rightLow; best.bottom = leftHigh; 
            return best; 
         }
      } else {
         double rightHigh = iHigh(sym, InpTF, i); 
         double leftLow = iLow(sym, InpTF, i+2);
         if(rightHigh < leftLow && (leftLow - rightHigh) > minGap) {
            best.valid = true; best.top = leftLow; best.bottom = rightHigh; 
            return best;
         }
      }
   }
   return best;
}

//+------------------------------------------------------------------+
//| EXECUTION & UTILITIES                                            |
//+------------------------------------------------------------------+
bool ExecuteTrade(string sym, int dir, double entry, double sl, double tp) {
   if(!SpreadOk(sym)) return false;
   
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if((dailyStartEquity - equity) / dailyStartEquity * 100.0 >= InpMaxDailyLoss) return false;

   int currentTrades = 0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      if(posInfo.SelectByIndex(i) && posInfo.Symbol() == sym && posInfo.Magic() == InpMagicNum) currentTrades++;
   }
   if(currentTrades >= InpMaxTotalTrades) return false;

   double dist = MathAbs(entry - sl);
   if(dist < InpMin_Stop_Dist * SymbolInfoDouble(sym, SYMBOL_POINT)) return false;

   double lots = CalculateRobustLots(sym, entry, sl, InpRisk_Per_Trade);
   if(lots <= 0) return false;

   double margin;
   ENUM_ORDER_TYPE type = (dir==1) ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT;
   if(!OrderCalcMargin(type, sym, lots, entry, margin)) return false;
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin) return false;

   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   string comm = "Hydra_Gold_v1";

   if(dir == 1) return trade.BuyLimit(lots, NormalizeDouble(entry, digits), sym, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), ORDER_TIME_GTC, 0, comm);
   else return trade.SellLimit(lots, NormalizeDouble(entry, digits), sym, NormalizeDouble(sl, digits), NormalizeDouble(tp, digits), ORDER_TIME_GTC, 0, comm);
}

double GetATR(int idx) {
   double buff[];
   if(CopyBuffer(handle_ATR, 0, idx, 1, buff) > 0) return buff[0];
   return 0;
}

bool SpreadOk(string sym) {
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double spread = ask - bid;
   double point = SymbolInfoDouble(sym, SYMBOL_POINT);
   if(spread > InpSpread_Max * point) return false;
   return true;
}

void CheckDailyDrawdown() {
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double dropPercent = (dailyStartEquity - currentEquity) / dailyStartEquity * 100.0;
   
   if(dropPercent >= InpMaxDailyLoss) {
      for(int i=PositionsTotal()-1; i>=0; i--) {
         if(posInfo.SelectByIndex(i)) trade.PositionClose(posInfo.Ticket());
      }
      for(int i=OrdersTotal()-1; i>=0; i--) {
         if(orderInfo.SelectByIndex(i)) trade.OrderDelete(orderInfo.Ticket());
      }
   }
}

bool IsNewDay() {
   datetime curr = TimeCurrent();
   MqlDateTime dt_curr, dt_last;
   TimeToStruct(curr, dt_curr);
   TimeToStruct(lastDayCheck, dt_last);
   if(dt_curr.day != dt_last.day) { lastDayCheck = curr; return true; }
   return false;
}

double CalculateRobustLots(string sym, double entry, double sl, double riskPct) {
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskMoney = equity * (riskPct / 100.0);
   double lossPerLot = 0;
   
   ENUM_ORDER_TYPE type = (entry > sl) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   if(!OrderCalcProfit(type, sym, 1.0, entry, sl, lossPerLot)) return 0;
   if(lossPerLot == 0) return 0;
   
   double rawLots = riskMoney / MathAbs(lossPerLot);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double lots = MathFloor(rawLots / step) * step;
   
   double min = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double max = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   
   if(lots < min) lots = min; 
   if(lots > max) lots = max;
   return lots;
}

void SetRobustFillingMode(string sym) {
   long fill = SymbolInfoInteger(sym, SYMBOL_FILLING_MODE);
   if((fill & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fill & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
}