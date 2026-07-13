//+------------------------------------------------------------------+
//|                                        ClipboardSignalTrader.mq5  |
//|  Manual, human-in-the-loop copying of Telegram/chat trade signals |
//|  from the Windows clipboard into an editable order table.         |
//|                                                                   |
//|  Philosophy: nothing reaches the market without an explicit OK.   |
//|  The parser only PROPOSES; every validation runs on the values    |
//|  AFTER the user has edited them.                                  |
//|                                                                   |
//|  For educational use. Test on a demo account first. Trading       |
//|  involves substantial risk of loss.                               |
//+------------------------------------------------------------------+
#property copyright "Alan Lipinski"
#property version   "1.10"
#property strict

#include <Trade/Trade.mqh>

//====================================================================
//  WINAPI IMPORT - read text from the clipboard (CF_UNICODETEXT = 13)
//  Requires "Allow DLL imports" to be enabled in the EA settings.
//====================================================================
#import "user32.dll"
   int  OpenClipboard(long hWndNewOwner);
   int  CloseClipboard(void);
   long GetClipboardData(int uFormat);
   int  IsClipboardFormatAvailable(int format);
#import
#import "kernel32.dll"
   long GlobalLock(long hMem);
   int  GlobalUnlock(long hMem);
   void RtlMoveMemory(ushort &dst[], long src, int size);
   int  lstrlenW(long ptr);
#import

#define CF_UNICODETEXT 13

enum ENUM_MAPSEL { MAP_1=0, MAP_2=1, MAP_3=2 };

//====================================================================
//  INPUTS
//====================================================================
input group "=== Position size ==="
input double  InpDefaultLot      = 0.01;   // Default lot proposed for each trade
input group "=== Trade adjustments (0 = off) ==="
input double  InpTPReducePct     = 0.0;    // Reduce each TP toward entry by this % of the entry->TP distance
input double  InpRiskIncreasePct = 0.0;    // Widen SL away from entry by this % of the entry->SL distance (more risk)
input group "=== Execution ==="
input ulong   InpMagicNumber     = 770001; // Magic number
input int     InpDeviationPoints = 20;     // Deviation / slippage (points)
input double  InpMaxPriceDevPct  = 3.0;    // Max entry deviation from market (%) - rejects stale/broken signals
input string  InpSymbolSuffix    = "";     // Broker suffix appended when a symbol is not found (e.g. "s")
input group "=== Symbol maps per broker ==="
input ENUM_MAPSEL InpActiveMap   = MAP_1;  // Which map is active
input string  InpMap1 = "XAUUSD=XAUUSDs;GOLD=XAUUSDs;XAU=XAUUSDs;US30=DJI30;DOW=DJI30;DJI30=DJI30;NAS100=NAS100;US100=NAS100;NASDAQ=NAS100;USTEC=NAS100;USDCAD=USDCAD;AUDCAD=AUDCAD"; // Map 1
input string  InpMap2 = "GOLD=XAUUSD;XAU=XAUUSD;DOW=US30;NASDAQ=NAS100;OIL=WTI"; // Map 2 (edit for your broker)
input string  InpMap3 = ""; // Map 3 (free slot)
input group "=== Panel ==="
input int     InpPanelX          = 15;     // Panel X
input int     InpPanelY          = 20;     // Panel Y

//====================================================================
//  CONSTANTS / STRUCTS
//====================================================================
#define MAXROWS 5
#define PFX "CST_"        // object name prefix

#define DIR_BUY  0
#define DIR_SELL 1
#define OT_MARKET 0
#define OT_LIMIT  1
#define OT_STOP   2

struct TxRow
{
   bool   used;     // parser produced this row
   bool   sel;      // selected for execution
   int    dir;      // DIR_BUY / DIR_SELL
   int    otype;    // OT_MARKET / OT_LIMIT / OT_STOP
   double entry;
   double sl;
   double tp;
   double lot;
};

CTrade  trade;
TxRow   g_rows[MAXROWS];

// signal-level data (not per row)
string  g_symRaw = "";
string  g_symRes = "";
string  g_status = "Paste a signal (Ctrl+C), then click Load.";
color   g_statusColor = clrGray;

// symbol map (parsed from the active slot)
string  g_mapKey[];
string  g_mapVal[];
int     g_mapN = 0;

//====================================================================
//  PANEL LAYOUT
//====================================================================
int X0, Y0;
const int ROWH = 24;
const int GRIDY_OFF = 86;   // from Y0 to the first row
// columns (offset from X0) and widths
const int cxChk=10,  cwChk=34;
const int cxDir=50,  cwDir=58;
const int cxEnt=112, cwEnt=86;
const int cxSL =202, cwSL =78;
const int cxTP =284, cwTP =78;
const int cxLot=366, cwLot=60;
const int cxTyp=430, cwTyp=74;
const int PANELW = 524;

//+------------------------------------------------------------------+
int OnInit()
{
   // hard reset (globals can survive a re-init on parameter change)
   ClearModel();

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(InpDeviationPoints);

   string activeMap = InpMap1;
   if(InpActiveMap==MAP_2)      activeMap = InpMap2;
   else if(InpActiveMap==MAP_3) activeMap = InpMap3;
   ParseSymbolMap(activeMap);

   X0 = InpPanelX;
   Y0 = InpPanelY;
   BuildPanel();
   RefreshGrid();

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   ObjectsDeleteAll(0, PFX);
   ChartRedraw();
}

//+------------------------------------------------------------------+
void OnTick() { }   // no tick logic - execution is manual

//====================================================================
//  MODEL
//====================================================================
void ClearModel()
{
   for(int i=0;i<MAXROWS;i++)
   {
      g_rows[i].used=false; g_rows[i].sel=false;
      g_rows[i].dir=DIR_BUY; g_rows[i].otype=OT_MARKET;
      g_rows[i].entry=0; g_rows[i].sl=0; g_rows[i].tp=0;
      g_rows[i].lot=InpDefaultLot;
   }
   g_symRaw=""; g_symRes="";
}

//====================================================================
//  SYMBOL MAP
//====================================================================
void ParseSymbolMap(string s)
{
   g_mapN=0; ArrayResize(g_mapKey,0); ArrayResize(g_mapVal,0);
   string pairs[];
   int n=StringSplit(s,';',pairs);
   for(int i=0;i<n;i++)
   {
      string p=pairs[i];
      StringTrimLeft(p); StringTrimRight(p);
      if(StringLen(p)==0) continue;
      int eq=StringFind(p,"=");
      if(eq<=0) continue;
      string k=StringSubstr(p,0,eq);
      string v=StringSubstr(p,eq+1);
      StringTrimLeft(k); StringTrimRight(k);
      StringTrimLeft(v); StringTrimRight(v);
      StringToUpper(k);
      ArrayResize(g_mapKey,g_mapN+1);
      ArrayResize(g_mapVal,g_mapN+1);
      g_mapKey[g_mapN]=k; g_mapVal[g_mapN]=v; g_mapN++;
   }
}

// clean a name: strip '#', trim, uppercase
string CleanSymbolName(string raw)
{
   string up=raw; StringToUpper(up);
   StringReplace(up,"#","");
   StringTrimLeft(up); StringTrimRight(up);
   return up;
}

// look up in the ACTIVE map (exact, then prefix before '-'); "" if none
string MapLookup(string up)
{
   for(int i=0;i<g_mapN;i++)
      if(g_mapKey[i]==up) return g_mapVal[i];
   int d=StringFind(up,"-");
   if(d>0)
   {
      string pre=StringSubstr(up,0,d);
      for(int i=0;i<g_mapN;i++)
         if(g_mapKey[i]==pre) return g_mapVal[i];
   }
   return "";
}

// best name to DISPLAY (parse-time), before availability is checked
string PreviewSymbol(string raw)
{
   string up=CleanSymbolName(raw);
   string m=MapLookup(up);
   return (m!="")?m:up;
}

// find a broker symbol that starts with the given prefix;
// on multiple hits pick the SHORTEST name (usually the canonical one).
string FindSymbolByPrefix(string prefixUp)
{
   int total=SymbolsTotal(false);
   string best=""; int bestLen=2147483647;
   for(int i=0;i<total;i++)
   {
      string nm=SymbolName(i,false);
      string up=nm; StringToUpper(up);
      if(StringFind(up,prefixUp)==0)
      {
         if(StringLen(nm)<bestLen){ best=nm; bestLen=StringLen(nm); }
      }
   }
   if(best!="" && SymbolSelect(best,true)) return best;
   return "";
}

// ORDER: 1) direct  2) active map  3) +suffix  4) 6-char prefix.
// Returns "" if nothing resolves.
string ResolveTradableSymbol(string raw)
{
   string up=CleanSymbolName(raw);

   // 1) direct - recognise the name as-is
   if(SymbolSelect(up,true)) return up;

   // 2) active map
   string mapped=MapLookup(up);
   if(mapped!="" && SymbolSelect(mapped,true)) return mapped;

   // base for further attempts: mapped if we had one, else the raw name
   string base=(mapped!="")?mapped:up;

   // 3) +broker suffix
   if(StringLen(InpSymbolSuffix)>0)
   {
      string c2=base+InpSymbolSuffix;
      if(SymbolSelect(c2,true)) return c2;
   }

   // 4) 6-char prefix (e.g. signal BTCUSD -> broker BTCUSDT)
   string bu=base; StringToUpper(bu);
   if(StringLen(bu)>=6)
   {
      string byPref=FindSymbolByPrefix(StringSubstr(bu,0,6));
      if(byPref!="") return byPref;
   }

   return "";
}

//====================================================================
//  CLIPBOARD READ
//====================================================================
string ClipboardGetText()
{
   string text="";
   if(IsClipboardFormatAvailable(CF_UNICODETEXT)==0) return "";
   if(OpenClipboard(0)==0) return "";
   long h=GetClipboardData(CF_UNICODETEXT);
   if(h!=0)
   {
      long ptr=GlobalLock(h);
      if(ptr!=0)
      {
         int len=lstrlenW(ptr);
         if(len>0 && len<100000)
         {
            ushort arr[];
            ArrayResize(arr,len+1);
            RtlMoveMemory(arr,ptr,(len+1)*2);
            text=ShortArrayToString(arr,0,len);
         }
         GlobalUnlock(h);
      }
   }
   CloseClipboard();
   return text;
}

//====================================================================
//  PARSER HELPERS
//====================================================================
bool IsLetterCh(ushort c){ return (c>='A'&&c<='Z')||(c>='a'&&c<='z'); }

string Upper(string s){ StringToUpper(s); return s; }

// does 'needle' occur as a "word" (non-letter boundaries)
bool WordFound(string hayUp,string needle)
{
   int nl=StringLen(needle), hl=StringLen(hayUp), from=0;
   while(true)
   {
      int p=StringFind(hayUp,needle,from);
      if(p<0) return false;
      bool okPre  = (p==0)      || !IsLetterCh(StringGetCharacter(hayUp,p-1));
      int after=p+nl;
      bool okPost = (after>=hl) || !IsLetterCh(StringGetCharacter(hayUp,after));
      if(okPre && okPost) return true;
      from=p+1;
   }
}

// does the line contain a token starting with "TP" (TP, TP1, TP2, TPI-typo...)
bool StartsWithTP(string up)
{
   string toks[];
   int tn=StringSplit(up,' ',toks);
   for(int i=0;i<tn;i++)
   {
      string t=CleanToken(toks[i]);
      if(StringLen(t)>=2 && StringSubstr(t,0,2)=="TP") return true;
   }
   return false;
}

// read the first number from position 'from'; returns val + endPos
bool ReadNumber(string s,int from,double &val,int &endPos)
{
   int n=StringLen(s), i=from;
   while(i<n){ ushort c=StringGetCharacter(s,i); if(c>='0'&&c<='9') break; i++; }
   if(i>=n) return false;
   string num=""; bool dot=false;
   while(i<n)
   {
      ushort c=StringGetCharacter(s,i);
      if(c>='0'&&c<='9'){ num+=ShortToString(c); i++; }
      else if((c=='.'||c==',') && !dot){ dot=true; num+="."; i++; }
      else break;
   }
   if(StringLen(num)==0) return false;
   val=StringToDouble(num); endPos=i;
   return true;
}

// value from a line: the LAST number on the line.
// The price is always at the end and the label index (1,2..) always
// precedes it, so this correctly skips "TP1" / "TP 2" with or without a colon.
bool LineValue(string line,double &val)
{
   int n=StringLen(line), i=0; bool found=false; double last=0; double v; int e;
   while(i<n)
   {
      if(ReadNumber(line,i,v,e)){ last=v; found=true; i=e; }
      else break;
   }
   val=last;
   return found;
}

//====================================================================
//  MAIN PARSER
//====================================================================
bool ParseSignal(string raw,string &errMsg)
{
   ClearModel();
   errMsg="";

   // normalise line endings
   StringReplace(raw,"\r","");
   string lines[];
   int nl=StringSplit(raw,'\n',lines);
   if(nl<=0){ errMsg="Empty text."; return false; }

   int    dir=-1, otype=OT_MARKET;
   double entry=0, sl=0;
   double tps[]; int tpN=0;
   string symRaw="";
   string entryNote="";

   // --- direction + order type (over the whole text) ---
   string allUp=Upper(raw);
   if(WordFound(allUp,"SELL")) dir=DIR_SELL;
   else if(WordFound(allUp,"BUY")) dir=DIR_BUY;

   if(StringFind(allUp,"LIMIT")>=0) otype=OT_LIMIT;
   else if(StringFind(allUp,"BUY STOP")>=0 || StringFind(allUp,"SELL STOP")>=0 ||
           StringFind(allUp,"BUY-STOP")>=0 || StringFind(allUp,"SELL-STOP")>=0 ||
           StringFind(allUp,"BUYSTOP")>=0  || StringFind(allUp,"SELLSTOP")>=0)
      otype=OT_STOP;

   // --- symbol ---
   symRaw=DetectSymbol(lines,nl);

   // --- line-by-line pass ---
   for(int i=0;i<nl;i++)
   {
      string line=lines[i];
      string up=Upper(line);
      if(StringLen(up)==0) continue;

      bool hasTP = StartsWithTP(up) || StringFind(up,"TAKE PROFIT")>=0 || WordFound(up,"TARGET");
      bool hasSL = StringFind(up,"STOP LOSS")>=0 || WordFound(up,"SL") || WordFound(up,"SI") || StringFind(up,"S/L")>=0;

      if(hasTP)
      {
         double v;
         if(LineValue(line,v) && v>0) AddTP(tps,tpN,v);
      }
      else if(hasSL)
      {
         double v;
         if(sl<=0 && LineValue(line,v) && v>0) sl=v;
      }
      else
      {
         // ENTRY: '@' -> ENTRY label -> a direction line with a number
         double v; int e;
         int at=StringFind(line,"@");
         bool hasEntryWord = (StringFind(up,"ENTRY")>=0);
         bool dirLine = WordFound(up,"BUY")||WordFound(up,"SELL");

         if(entry<=0 && at>=0)
         {
            if(ReadNumber(line,at+1,v,e) && v>0)
            {
               // check for a range "@lo-hi"
               int j=e; while(j<StringLen(line) && StringGetCharacter(line,j)==' ') j++;
               if(j<StringLen(line) && StringGetCharacter(line,j)=='-')
               {
                  double hi; int e2;
                  if(ReadNumber(line,j+1,hi,e2) && hi>0)
                  { entry=(v+hi)/2.0; entryNote=StringFormat("range %.5g-%.5g -> mid",v,hi); }
                  else entry=v;
               }
               else entry=v;
            }
         }
         else if(entry<=0 && hasEntryWord)
         {
            if(LineValue(line,v) && v>0) entry=v;
         }
         else if(entry<=0 && dirLine)
         {
            // number after the BUY/SELL token on the same line (e.g. "XAUUSD BUY 4051.50")
            int dp=StringFind(up,"SELL"); if(dp<0) dp=StringFind(up,"BUY");
            if(dp>=0 && ReadNumber(line,dp,v,e) && v>0) entry=v;
         }
      }
   }

   // --- completeness ---
   if(dir<0){ errMsg="No direction (BUY/SELL)."; return false; }
   if(symRaw==""){ errMsg="Symbol not recognised."; return false; }
   if(entry<=0){ errMsg="No entry price."; return false; }
   if(sl<=0){ errMsg="No SL."; return false; }
   if(tpN<=0){ errMsg="No TP."; return false; }

   // --- order-of-magnitude sanity: SL/TP must be same order as entry ---
   // (catches a label index parsed as a value, e.g. TP=1 with entry=4066)
   double loBand=entry/3.0, hiBand=entry*3.0;
   if(sl<loBand || sl>hiBand)
   { errMsg=StringFormat("SL=%.5g unrealistic vs entry=%.5g - parse error?",sl,entry); return false; }
   for(int i=0;i<tpN;i++)
      if(tps[i]<loBand || tps[i]>hiBand)
      { errMsg=StringFormat("TP=%.5g unrealistic vs entry=%.5g - parse error?",tps[i],entry); return false; }

   // --- build rows (apply trade adjustments here so they show in the table) ---
   g_symRaw=symRaw;
   string resolved=ResolveTradableSymbol(symRaw);   // direct -> map -> suffix -> prefix
   g_symRes=(resolved!="")?resolved:PreviewSymbol(symRaw);

   double tpCut   = MathMax(0.0, InpTPReducePct);      // reduce TP distance
   double slWiden = MathMax(0.0, InpRiskIncreasePct);  // widen SL distance (more risk)
   int rows=MathMin(tpN,MAXROWS);
   for(int i=0;i<rows;i++)
   {
      g_rows[i].used=true;
      g_rows[i].sel=true;
      g_rows[i].dir=dir;
      g_rows[i].otype=otype;
      g_rows[i].entry=entry;
      // widen SL away from entry by slWiden% of the entry->SL distance
      g_rows[i].sl = entry + (sl-entry)*(1.0 + slWiden/100.0);
      // reduce TP toward entry by tpCut% of the entry->TP distance
      g_rows[i].tp = entry + (tps[i]-entry)*(1.0 - tpCut/100.0);
      g_rows[i].lot = InpDefaultLot;   // execution normalises to the broker lot step
   }

   string note = (entryNote!="") ? (" ["+entryNote+"]") : "";
   g_status = StringFormat("OK: %s->%s, %s, %d TP%s",
                 symRaw, g_symRes, (dir==DIR_BUY?"BUY":"SELL"), rows, note);
   g_statusColor=clrLimeGreen;
   return true;
}

// add a TP if new (dedup by value) and there is room
void AddTP(double &tps[],int &n,double v)
{
   for(int i=0;i<n;i++) if(MathAbs(tps[i]-v)<1e-9) return; // duplicate (double paste)
   if(n>=MAXROWS) return;
   ArrayResize(tps,n+1);
   tps[n]=v; n++;
}

// detect the symbol among tokens
string DetectSymbol(string &lines[],int nl)
{
   // keywords to skip
   string kw[] = {"BUY","SELL","TP","TP1","TP2","TP3","TP4","TP5","SL","SI",
                  "ENTRY","POINT","STOP","LOSS","LIMIT","PROFIT","TAKE","TARGET",
                  "SIGNAL","ALERT","TRADE","DETAILS","KEEP","RISK","BALANCE",
                  "SCALPER","INTRADAY","SWING","NOW","AT"};
   for(int i=0;i<nl;i++)
   {
      string toks[];
      string norm=lines[i];
      StringReplace(norm,"@"," ");
      StringReplace(norm,":"," ");
      int tn=StringSplit(norm,' ',toks);
      for(int t=0;t<tn;t++)
      {
         string tk=CleanToken(toks[t]);
         if(StringLen(tk)<3) continue;
         string up=tk; StringToUpper(up);
         // skip keywords and pure numbers
         bool isKw=false;
         for(int k=0;k<ArraySize(kw);k++) if(kw[k]==up){ isKw=true; break; }
         if(isKw) continue;
         if(IsNumericToken(up)) continue;
         // 1) map hit
         for(int m=0;m<g_mapN;m++) if(g_mapKey[m]==up) return up;
         // 2) symbol shape: letters, digits, '-'
         if(LooksLikeSymbol(up)) return up;
      }
   }
   return "";
}

// strip characters outside [A-Za-z0-9-] (emoji, '#', punctuation)
string CleanToken(string s)
{
   string o="";
   for(int i=0;i<StringLen(s);i++)
   {
      ushort c=StringGetCharacter(s,i);
      if((c>='A'&&c<='Z')||(c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-')
         o+=ShortToString(c);
   }
   return o;
}

bool IsNumericToken(string s)
{
   bool anyDigit=false;
   for(int i=0;i<StringLen(s);i++)
   {
      ushort c=StringGetCharacter(s,i);
      if(c>='0'&&c<='9') anyDigit=true;
      else if(c=='.'||c==','||c=='-') continue;
      else return false;
   }
   return anyDigit;
}

// symbol = at least 2 letters, digits and '-' allowed
bool LooksLikeSymbol(string up)
{
   int letters=0;
   for(int i=0;i<StringLen(up);i++)
   {
      ushort c=StringGetCharacter(up,i);
      if(c>='A'&&c<='Z') letters++;
      else if((c>='0'&&c<='9')||c=='-') continue;
      else return false;
   }
   return letters>=2;
}

//====================================================================
//  VALIDATION GATE + EXECUTION
//====================================================================
void OnExecute()
{
   if(g_symRaw==""){ SetStatus("Load a signal first.",clrOrange); return; }

   string sym=ResolveTradableSymbol(g_symRaw);
   if(sym=="")
   {
      SetStatus(StringFormat("Symbol '%s' not available at broker (map/suffix/6-char prefix).",g_symRes),clrRed);
      return;
   }
   // show the symbol actually used (e.g. BTCUSD -> BTCUSDT)
   if(sym!=g_symRes) SetText(PFX+"symlbl", g_symRes+" -> "+sym);
   else              SetText(PFX+"symlbl", sym);

   int    digits = (int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(sym,SYMBOL_POINT);
   double bid    = SymbolInfoDouble(sym,SYMBOL_BID);
   double ask    = SymbolInfoDouble(sym,SYMBOL_ASK);
   double mkt    = (bid+ask)/2.0;
   int    stops  = (int)SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
   double minDist= stops*point;
   double minLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   double lotStep= SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);

   ApplyFilling(sym);

   int okCnt=0, failCnt=0;
   string lastErr="";

   for(int i=0;i<MAXROWS;i++)
   {
      if(!g_rows[i].used || !g_rows[i].sel) continue;

      double entry=NormalizeDouble(g_rows[i].entry,digits);
      double slp  =NormalizeDouble(g_rows[i].sl,digits);
      double tpp  =NormalizeDouble(g_rows[i].tp,digits);
      double lot  =NormLot(g_rows[i].lot,minLot,maxLot,lotStep);
      int    dir  =g_rows[i].dir;
      int    ot   =g_rows[i].otype;

      // -- basics --
      if(entry<=0||slp<=0||tpp<=0){ failCnt++; lastErr=StringFormat("R%d: missing values",i+1); continue; }
      if(lot<minLot){ failCnt++; lastErr=StringFormat("R%d: lot < min",i+1); continue; }

      // -- geometry (on the values AFTER editing) --
      if(dir==DIR_BUY && !(slp<entry && entry<tpp))
      { failCnt++; lastErr=StringFormat("R%d: BUY requires SL<entry<TP",i+1); continue; }
      if(dir==DIR_SELL && !(tpp<entry && entry<slp))
      { failCnt++; lastErr=StringFormat("R%d: SELL requires TP<entry<SL",i+1); continue; }

      // -- price sanity vs market --
      if(mkt>0 && MathAbs(entry-mkt)/mkt*100.0 > InpMaxPriceDevPct)
      { failCnt++; lastErr=StringFormat("R%d: entry deviates >%.1f%% from market",i+1,InpMaxPriceDevPct); continue; }

      // -- stops level --
      double refP = (ot==OT_MARKET) ? ((dir==DIR_BUY)?ask:bid) : entry;
      if(minDist>0 && (MathAbs(refP-slp)<minDist || MathAbs(refP-tpp)<minDist))
      { failCnt++; lastErr=StringFormat("R%d: SL/TP too close (stops level)",i+1); continue; }

      // -- pick the concrete order + side check --
      bool ok=false; string cmt=StringFormat("CST TP%d",i+1);

      if(ot==OT_MARKET)
      {
         if(dir==DIR_BUY) ok=trade.Buy(lot,sym,0,slp,tpp,cmt);
         else             ok=trade.Sell(lot,sym,0,slp,tpp,cmt);
      }
      else if(ot==OT_LIMIT)
      {
         if(dir==DIR_BUY)
         {
            if(entry>=ask){ failCnt++; lastErr=StringFormat("R%d: BUY LIMIT requires entry < market",i+1); continue; }
            ok=trade.BuyLimit(lot,entry,sym,slp,tpp);
         }
         else
         {
            if(entry<=bid){ failCnt++; lastErr=StringFormat("R%d: SELL LIMIT requires entry > market",i+1); continue; }
            ok=trade.SellLimit(lot,entry,sym,slp,tpp);
         }
      }
      else // OT_STOP
      {
         if(dir==DIR_BUY)
         {
            if(entry<=ask){ failCnt++; lastErr=StringFormat("R%d: BUY STOP requires entry > market",i+1); continue; }
            ok=trade.BuyStop(lot,entry,sym,slp,tpp);
         }
         else
         {
            if(entry>=bid){ failCnt++; lastErr=StringFormat("R%d: SELL STOP requires entry < market",i+1); continue; }
            ok=trade.SellStop(lot,entry,sym,slp,tpp);
         }
      }

      if(ok) okCnt++;
      else { failCnt++; lastErr=StringFormat("R%d: %s",i+1,trade.ResultRetcodeDescription()); }
   }

   if(failCnt==0 && okCnt>0)
      SetStatus(StringFormat("Sent %d trade(s).",okCnt),clrLimeGreen);
   else if(okCnt>0)
      SetStatus(StringFormat("Sent %d, failed %d. Last: %s",okCnt,failCnt,lastErr),clrOrange);
   else
      SetStatus(StringFormat("Nothing sent. %s",lastErr),clrRed);
}

void ApplyFilling(string sym)
{
   long fm=SymbolInfoInteger(sym,SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK)!=0)      trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((fm & SYMBOL_FILLING_IOC)!=0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else                                  trade.SetTypeFilling(ORDER_FILLING_RETURN);
}

double NormLot(double lot,double mn,double mx,double step)
{
   if(step<=0) step=0.01;
   lot=MathFloor(lot/step)*step;
   if(lot<mn) lot=mn;
   if(lot>mx) lot=mx;
   return NormalizeDouble(lot,2);
}

//====================================================================
//  GUI - BUILD
//====================================================================
void BuildPanel()
{
   ObjectsDeleteAll(0,PFX);

   int panelH = GRIDY_OFF + MAXROWS*ROWH + 34;
   MkRect(PFX+"bg", X0, Y0, PANELW, panelH, C'34,34,40', C'70,70,80');
   MkLabel(PFX+"title", X0+10, Y0+6, "Clipboard Signal Trader", clrWhite, 10);

   // action buttons
   MkButton(PFX+"btnLoad",  X0+10,  Y0+28, 110, 22, "Load",     C'40,70,110', clrWhite);
   MkButton(PFX+"btnExec",  X0+128, Y0+28, 90,  22, "OK / Send", C'40,110,60', clrWhite);
   MkButton(PFX+"btnClear", X0+224, Y0+28, 74,  22, "Clear",    C'90,60,40', clrWhite);
   MkLabel (PFX+"symlbl",   X0+310, Y0+32, "", clrGold, 9);

   // table header
   int hy=Y0+62;
   MkLabel(PFX+"h_sel", X0+cxChk, hy, "Y/N",   clrSilver, 8);
   MkLabel(PFX+"h_dir", X0+cxDir, hy, "DIR",   clrSilver, 8);
   MkLabel(PFX+"h_ent", X0+cxEnt, hy, "ENTRY", clrSilver, 8);
   MkLabel(PFX+"h_sl",  X0+cxSL,  hy, "SL",    clrSilver, 8);
   MkLabel(PFX+"h_tp",  X0+cxTP,  hy, "TP",    clrSilver, 8);
   MkLabel(PFX+"h_lot", X0+cxLot, hy, "LOT",   clrSilver, 8);
   MkLabel(PFX+"h_typ", X0+cxTyp, hy, "TYPE",  clrSilver, 8);

   // rows
   for(int i=0;i<MAXROWS;i++)
   {
      int ry=Y0+GRIDY_OFF+i*ROWH;
      string s=IntegerToString(i);
      MkButton(PFX+"chk_"+s, X0+cxChk, ry, cwChk, 20, "", C'60,60,70', clrWhite);
      MkButton(PFX+"dir_"+s, X0+cxDir, ry, cwDir, 20, "", C'60,60,70', clrWhite);
      MkEdit  (PFX+"ent_"+s, X0+cxEnt, ry, cwEnt, 20, "");
      MkEdit  (PFX+"sl_"+s,  X0+cxSL,  ry, cwSL,  20, "");
      MkEdit  (PFX+"tp_"+s,  X0+cxTP,  ry, cwTP,  20, "");
      MkEdit  (PFX+"lot_"+s, X0+cxLot, ry, cwLot, 20, "");
      MkButton(PFX+"typ_"+s, X0+cxTyp, ry, cwTyp, 20, "", C'60,60,70', clrWhite);
   }

   // status
   MkLabel(PFX+"status", X0+10, Y0+GRIDY_OFF+MAXROWS*ROWH+8, g_status, g_statusColor, 8);

   ChartRedraw();
}

//====================================================================
//  GUI - REFRESH
//====================================================================
void RefreshGrid()
{
   if(g_symRes!="") SetText(PFX+"symlbl", g_symRes);
   else             SetText(PFX+"symlbl", "");

   for(int i=0;i<MAXROWS;i++)
   {
      string s=IntegerToString(i);
      TxRow r=g_rows[i];

      // checkbox
      SetBtn(PFX+"chk_"+s, r.sel?"[x]":"[ ]", r.sel?C'40,110,60':C'60,60,70');
      // direction
      SetBtn(PFX+"dir_"+s, (r.dir==DIR_BUY)?"BUY":"SELL", (r.dir==DIR_BUY)?C'40,90,140':C'150,50,50');
      // type
      string tt=(r.otype==OT_MARKET)?"MKT":((r.otype==OT_LIMIT)?"LMT":"STP");
      SetBtn(PFX+"typ_"+s, tt, C'70,70,80');

      // numeric fields (empty when the row is unused)
      if(r.used)
      {
         SetText(PFX+"ent_"+s, FmtPrice(r.entry));
         SetText(PFX+"sl_"+s,  FmtPrice(r.sl));
         SetText(PFX+"tp_"+s,  FmtPrice(r.tp));
         SetText(PFX+"lot_"+s, DoubleToString(r.lot,2));
      }
      else
      {
         SetText(PFX+"ent_"+s,""); SetText(PFX+"sl_"+s,"");
         SetText(PFX+"tp_"+s,"");  SetText(PFX+"lot_"+s,"");
      }
   }
   SetStatus(g_status,g_statusColor);
   ChartRedraw();
}

// price format - use the symbol digits if known, otherwise trim zeros
string FmtPrice(double v)
{
   string sym=(g_symRes!="")?g_symRes:"";
   if(sym!="" && SymbolInfoInteger(sym,SYMBOL_DIGITS)>0)
   {
      int d=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
      return DoubleToString(v,d);
   }
   string s=DoubleToString(v,5);
   while(StringLen(s)>0 && StringGetCharacter(s,StringLen(s)-1)=='0')
      s=StringSubstr(s,0,StringLen(s)-1);
   if(StringLen(s)>0 && StringGetCharacter(s,StringLen(s)-1)=='.')
      s=StringSubstr(s,0,StringLen(s)-1);
   return s;
}

//====================================================================
//  EVENT HANDLING
//====================================================================
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam==PFX+"btnLoad")  { OnLoad();  ResetBtn(sparam); return; }
      if(sparam==PFX+"btnExec")  { OnExecute(); RefreshGrid(); ResetBtn(sparam); return; }
      if(sparam==PFX+"btnClear") { ClearModel(); g_status="Cleared."; g_statusColor=clrGray; RefreshGrid(); ResetBtn(sparam); return; }

      int idx;
      if(RowIdx(sparam,"chk_",idx))
      {
         if(!g_rows[idx].used)
         {
            // empty row: copy from the nearest filled row above ("load 2, open 3")
            int src=-1;
            for(int k=idx-1;k>=0;k--) if(g_rows[k].used){ src=k; break; }
            if(src>=0)
            {
               g_rows[idx]=g_rows[src];   // struct copy (entry/SL/TP/lot/dir/type)
               g_rows[idx].used=true;
               g_rows[idx].sel=true;
            }
            // no source above -> do nothing (don't select an empty row)
         }
         else
         {
            g_rows[idx].sel=!g_rows[idx].sel;
         }
         RefreshGrid(); ResetBtn(sparam); return;
      }
      if(RowIdx(sparam,"dir_",idx)) { g_rows[idx].dir=(g_rows[idx].dir==DIR_BUY)?DIR_SELL:DIR_BUY; RefreshGrid(); ResetBtn(sparam); return; }
      if(RowIdx(sparam,"typ_",idx)) { g_rows[idx].otype=(g_rows[idx].otype+1)%3; RefreshGrid(); ResetBtn(sparam); return; }
   }
   else if(id==CHARTEVENT_OBJECT_ENDEDIT)
   {
      int idx;
      string txt=ObjectGetString(0,sparam,OBJPROP_TEXT);
      double v=StringToDouble(txt);
      if(RowIdx(sparam,"ent_",idx)) { g_rows[idx].entry=v; if(v>0) g_rows[idx].used=true; return; }
      if(RowIdx(sparam,"sl_",idx))  { g_rows[idx].sl=v; return; }
      if(RowIdx(sparam,"tp_",idx))  { g_rows[idx].tp=v; if(v>0) g_rows[idx].used=true; return; }
      if(RowIdx(sparam,"lot_",idx)) { g_rows[idx].lot=v; return; }
   }
}

void OnLoad()
{
   string txt=ClipboardGetText();
   if(txt=="")
   {
      SetStatus("Clipboard empty or DLL blocked (enable Allow DLL imports).",clrOrange);
      return;
   }
   string err;
   if(ParseSignal(txt,err))
      RefreshGrid();
   else
      SetStatus("Parse error: "+err,clrRed);
}

// extract the row number from an object name, e.g. "CST_chk_2" + "chk_" -> 2
bool RowIdx(string name,string role,int &idx)
{
   string pref=PFX+role;
   if(StringFind(name,pref)!=0) return false;
   string num=StringSubstr(name,StringLen(pref));
   idx=(int)StringToInteger(num);
   return (idx>=0 && idx<MAXROWS);
}

//====================================================================
//  OBJECT HELPERS
//====================================================================
void MkRect(string n,int x,int y,int w,int h,color bg,color brd)
{
   ObjectCreate(0,n,OBJ_RECTANGLE_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_BORDER_TYPE,BORDER_FLAT);
   ObjectSetInteger(0,n,OBJPROP_COLOR,brd);
   ObjectSetInteger(0,n,OBJPROP_BACK,false);
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}

void MkLabel(string n,int x,int y,string txt,color c,int fs)
{
   ObjectCreate(0,n,OBJ_LABEL,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,fs);
   ObjectSetString (0,n,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}

void MkButton(string n,int x,int y,int w,int h,string txt,color bg,color c)
{
   ObjectCreate(0,n,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);
   ObjectSetString (0,n,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}

void MkEdit(string n,int x,int y,int w,int h,string txt)
{
   ObjectCreate(0,n,OBJ_EDIT,0,0,0);
   ObjectSetInteger(0,n,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,n,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,n,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,n,OBJPROP_XSIZE,w);
   ObjectSetInteger(0,n,OBJPROP_YSIZE,h);
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,C'240,240,240');
   ObjectSetInteger(0,n,OBJPROP_COLOR,clrBlack);
   ObjectSetInteger(0,n,OBJPROP_ALIGN,ALIGN_RIGHT);
   ObjectSetInteger(0,n,OBJPROP_READONLY,false);
   ObjectSetInteger(0,n,OBJPROP_FONTSIZE,8);
   ObjectSetString (0,n,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(0,n,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,n,OBJPROP_HIDDEN,true);
}

void SetText(string n,string txt){ ObjectSetString(0,n,OBJPROP_TEXT,txt); }

void SetBtn(string n,string txt,color bg)
{
   ObjectSetString (0,n,OBJPROP_TEXT,txt);
   ObjectSetInteger(0,n,OBJPROP_BGCOLOR,bg);
   ObjectSetInteger(0,n,OBJPROP_STATE,false);
}

void ResetBtn(string n){ ObjectSetInteger(0,n,OBJPROP_STATE,false); ChartRedraw(); }

void SetStatus(string txt,color c)
{
   g_status=txt; g_statusColor=c;
   ObjectSetString(0,PFX+"status",OBJPROP_TEXT,txt);
   ObjectSetInteger(0,PFX+"status",OBJPROP_COLOR,c);
   ChartRedraw();
}
//+------------------------------------------------------------------+
