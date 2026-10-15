//+------------------------------------------------------------------+
//|                                                Consenso_WIN.mq5  |
//|                                                                   |
//|  Une os 4 robos em um so, por VOTACAO de peso igual:              |
//|                                                                   |
//|   Voto 1 - Delta_Fluxo   (divergencia de delta / absorcao)        |
//|   Voto 2 - Fita          (grandes lotes / velocidade / desequil.) |
//|   Voto 3 - VP_Breakout   (rompimento da Value Area)               |
//|   Voto 4 - Agressao      (agressao no Times & Trades)             |
//|                                                                   |
//|  Cada robo vota +1 (compra), -1 (venda) ou nao vota. O voto vale  |
//|  por InpVotoValidade barras M1 depois de emitido, e nunca passa   |
//|  de um dia para o outro.                                          |
//|                                                                   |
//|  REGRAS                                                           |
//|   - 3 ou 4 votos do mesmo lado -> sinal (mesmo com 1 contra).     |
//|   - Entrada por ordem LIMITE:                                     |
//|       modo FECHAMENTO: compra = fechamento - distancia            |
//|                        venda  = fechamento + distancia            |
//|       modo EXTREMO   : compra = minima - distancia                |
//|                        venda  = maxima + distancia                |
//|   - Validade da limite: 4 barras (4 votos) / 3 barras (3 votos).  |
//|   - Stop 120 / alvo 75 pontos.                                    |
//|   - Reversao: 3+ votos do lado contrario com posicao aberta ->    |
//|     zera a mercado e envia a limite do lado novo. Com ordem       |
//|     pendente do outro lado: cancela e envia a nova.               |
//|                                                                   |
//|  Conta NETTING (B3, XP/Clear): uma posicao por vez, um magic so.  |
//|  Nao rode os 4 robos antigos no mesmo ativo junto com este.       |
//|  No testador use "cada tick com base em ticks reais".             |
//|                                                                   |
//|  v1.01 - revisao:                                                 |
//|   - consenso controlado por "chave" (voto mais novo): nao perde   |
//|     o voto da Fita na virada da barra e nao repete consenso velho |
//|   - reversao checada antes da ordem pendente                      |
//|   - zera na reversao mesmo fora do horario, mas so abre dentro    |
//|   - empate (ex.: 2x2 com InpVotosMin=2) nao opera                 |
//|   - votos de ontem nao valem hoje                                 |
//|   - pivo do Delta so e marcado quando o voto sai de fato          |
//|   - modo cauteloso da Fita restaurado                             |
//|   - ORDER_FILLING_RETURN na B3 e validade DAY/GTC conforme ativo  |
//|   - tentativa nao concluida (falha de envio) repete na barra      |
//|     seguinte enquanto os votos valerem                            |
//|                                                                   |
//|  v1.02 - painel no grafico: cada robo COMPRADO / VENDIDO /        |
//|          SEM SINAL, placar de votos e status. Resumo no log a     |
//|          cada barra em que os votos mudam.                        |
//|                                                                   |
//|  v1.03 - padroes para mais entradas: voto vale 5 barras, limite  |
//|          no fechamento (distancia 0), Agressao com fator 2.0,     |
//|          filtro de tendencia do Delta e da Fita desligados.       |
//|                                                                   |
//|  v1.04 - limite a 200 pontos. A distancia passa a valer tambem    |
//|          no modo fechamento (compra fech - dist / venda fech +).  |
//|                                                                   |
//|  v1.05 - painel mostra a LEITURA ao vivo de cada robo (mesmo sem  |
//|          votar) e se ha ticks de negocio com lado agressor.       |
//|          Sem eles Delta/Fita/Agressao ficam parados.              |
//+------------------------------------------------------------------+
#property copyright "Maikon"
#property version   "1.05"

#include <Trade\Trade.mqh>

//==================================================================
//  CONSENSO E ORDEM
//==================================================================
enum EModoPreco
{
   PRECO_FECHAMENTO = 0,   // Compra: fechamento - dist | Venda: fechamento + dist
   PRECO_EXTREMO    = 1    // Compra: minima - dist | Venda: maxima + dist
};

input group "Consenso"
input int        InpVotosMin      = 3;      // Votos do mesmo lado para entrar (3 de 4)
input int        InpVotoValidade  = 5;      // Barras M1 que um voto continua valendo
input bool       InpUsarDelta     = true;   // Voto 1: Delta_Fluxo
input bool       InpUsarFita      = true;   // Voto 2: Fita
input bool       InpUsarVP        = true;   // Voto 3: VP_Breakout
input bool       InpUsarAgressao  = true;   // Voto 4: Agressao

input group "Ordem limite"
input EModoPreco InpModoPreco     = PRECO_FECHAMENTO; // Preco da ordem limite
input int        InpDistancia     = 200;    // Distancia da limite (pontos) - vale nos dois modos
input int        InpValidade4     = 4;      // Validade com 4 votos (barras)
input int        InpValidade3     = 3;      // Validade com 3 votos (barras)
input double     InpLots          = 1.0;    // Contratos
input int        InpStopPoints    = 120;    // Stop (pontos)
input int        InpTakePoints    = 75;     // Alvo (pontos)
input bool       InpReverter      = true;   // 3+ votos contrarios: zera e vira

input group "Horario (servidor)"
input bool       InpUseTimeFilter = true;   // Filtro de horario para NOVAS entradas
input string     InpInicio        = "09:15";
input string     InpFimEntradas   = "17:15";
input bool       InpZerarFimDia   = true;   // Zerar no horario abaixo
input string     InpZerar         = "17:50";

input group "Operacional"
input ulong      InpMagic         = 777001;
input int        InpSlippage      = 20;
input bool       InpLog           = true;

input group "Painel"
input bool       InpMostrarPainel = true;              // Mostrar painel no grafico
input int        InpPainelX       = 14;                // Posicao X (pixels)
input int        InpPainelY       = 26;                // Posicao Y (pixels)
input color      InpCorTexto      = clrSilver;         // Texto
input color      InpCorCompra     = clrMediumSeaGreen; // Comprado
input color      InpCorVenda      = clrIndianRed;      // Vendido
input color      InpCorFundo      = C'22,22,26';       // Fundo

//==================================================================
//  FILTROS COMPARTILHADOS
//==================================================================
input group "Tendencia (Delta e Fita)"
input ENUM_TIMEFRAMES T_TF       = PERIOD_M15;  // Timeframe da media
input int             T_Periodo  = 50;          // Periodo da media
input ENUM_MA_METHOD  T_Metodo   = MODE_EMA;    // Metodo da media
input int             T_DistMin  = 50;          // Zona neutra (pontos)

input group "Modo cauteloso (VP e Fita)"
input int    C_JanelaMin = 30;    // Janela de leitura (minutos)
input int    C_Pts       = 200;   // Recuo minimo para contar uma reversao (pontos)
input int    C_Reversoes = 2;     // Reversoes que ligam o modo cauteloso
input int    C_HoldMin   = 20;    // Fica cauteloso por no minimo (minutos)

//==================================================================
//  VOTO 1 - DELTA_FLUXO
//==================================================================
input group "Voto 1 - Delta_Fluxo"
input bool   D_UsarDivergencia = true;   // Divergencia de delta
input bool   D_UsarAbsorcao    = true;   // Absorcao
input long   D_DeltaMinimo     = 400;    // Absorcao: delta minimo da barra
input int    D_RangeMaximo     = 60;     // Absorcao: range maximo (pontos)
input int    D_Lookback        = 60;     // Barras para procurar pivos
input int    D_PivotK          = 2;      // Barras de cada lado do pivo
input int    D_MaxPivotAge     = 5;      // Idade maxima do pivo recente
input double D_MinPriceDiff    = 30;     // Diferenca minima de preco (pontos)
input long   D_MinDeltaDiff    = 200;    // Diferenca minima de delta
input bool   D_FiltroTend      = false;  // So a favor da media

//==================================================================
//  VOTO 2 - FITA
//==================================================================
input group "Voto 2 - Fita"
input bool   F_UsarGrandes     = true;
input bool   F_UsarVelocidade  = true;
input bool   F_UsarDesequil    = true;
input int    F_MinSinais       = 2;      // Sinais internos que precisam concordar
input int    F_JanelaSeg       = 15;     // Janela curta (s)
input int    F_JanelaBaseSeg   = 600;    // Janela base da velocidade (s)
input long   F_LoteGrande      = 50;
input long   F_LoteTeto        = 1000;   // 0 = sem teto
input long   F_VolGrandesMin   = 200;
input double F_FatorVelocidade = 3.0;
input int    F_MinNegocios     = 20;
input double F_DesequilMin     = 0.60;
input long   F_VolMinJanela    = 300;
input bool   F_UsarAcumulado   = true;   // Barra sinal contra a variacao do acumulado
input int    F_AcumJanelaSeg   = 600;
input long   F_AcumMinimo      = 500;
input bool   F_FiltroTend      = false;
input int    F_SinaisIgnoraTend= 3;      // N sinais internos ignoram a tendencia (0 = nunca)
input bool   F_UsarChop        = true;   // Modo cauteloso exige mais sinais
input int    F_ChopMinSinais   = 3;      // Sinais exigidos no modo cauteloso

//==================================================================
//  VOTO 3 - VP_BREAKOUT
//==================================================================
input group "Voto 3 - VP_Breakout"
input int    V_ProfileBars     = 120;
input int    V_Bins            = 50;
input double V_ValueAreaPct    = 70.0;
input bool   V_UseTickVolume   = false;
input double V_BreakBufferATR  = 0.10;
input double V_MinVAWidthATR   = 1.00;
input bool   V_UsarChop        = true;   // Modo cauteloso aumenta a folga
input double V_ChopFator       = 2.0;

//==================================================================
//  VOTO 4 - AGRESSAO
//==================================================================
input group "Voto 4 - Agressao"
input int    A_JanelaSeg       = 10;
input int    A_NiveisMin       = 3;
input double A_FatorVolume     = 2.0;
input double A_DominioPct      = 70;
input int    A_MediaN          = 30;
input bool   A_ExigirSustentar = true;

//+------------------------------------------------------------------+
//| ESTADO                                                           |
//+------------------------------------------------------------------+
#define NVOTOS 4
string NOMES[NVOTOS] = {"Delta", "Fita", "VP", "Agressao"};

struct Voto
{
   int      dir;     // +1 / -1 / 0
   datetime barra;   // abertura da barra M1 em que o voto nasceu
};
Voto votos[NVOTOS];

CTrade   trade;
datetime lastBarTime = 0;
datetime ordemBarra  = 0;   // barra em que a limite foi enviada
int      ordemValid  = 0;   // validade dela em barras
ENUM_ORDER_TYPE_TIME tipoValidade = ORDER_TIME_DAY;

//--- ultimo consenso ja tratado (direcao + voto mais novo dele)
int      consDir   = 0;
datetime consChave = 0;

int      hMA  = INVALID_HANDLE;
int      hATR = INVALID_HANDLE;
int      fitaSinaisAtivos = 0;

//--- Delta: cache por barra (indice 0 = ultima fechada)
long     dBar[], dCum[];
datetime dTime[];
int      dCacheSize = 0;
datetime ultimoPivoTopo = 0, ultimoPivoFundo = 0;

//--- Fita: janela base deslizante e acumulado
long     baseSeg[];
int      baseN = 0, baseCheios = 0;
long     baseTotal = 0;
ulong    baseUltSeg = 0;
long     deltaAcum = 0;
ulong    acumAteMs = 0;
datetime diaDoAcum = 0;
long     acumHist[];
int      acumHistN = 0, acumHistCheios = 0;
ulong    acumHistSeg = 0;
long     acumVariacao = 0;
ulong    ultimaAvaliacaoMs = 0;

//--- modo cauteloso
datetime chopUltBarra = 0, chopAte = 0;
bool     chopAtivo = false;

//--- painel
#define  PFX "CONS_"
bool     painelAtivo = false;
datetime painelUltSeg = 0;
string   leitura[NVOTOS];   // o que cada robo esta lendo agora (painel)
int      diagTicks = -1;    // negocios na ultima barra fechada
double   diagFlagsPct = 0;  // % desses negocios com lado agressor
bool     avisoTicks = false;

//+------------------------------------------------------------------+
//| INIT                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippage);

   //--- B3 (execucao em bolsa): RETURN deixa a limite no book.
   //--- Em outro tipo de execucao, usa o que o simbolo permitir.
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE) == SYMBOL_TRADE_EXECUTION_EXCHANGE)
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
   else
      trade.SetTypeFillingBySymbol(_Symbol);

   //--- validade DAY se o ativo aceitar, senao GTC (a validade em barras e nossa)
   int expModes = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   tipoValidade = ((expModes & SYMBOL_EXPIRATION_DAY) != 0) ? ORDER_TIME_DAY : ORDER_TIME_GTC;

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Conta hedging: o EA continua operando uma posicao por vez");

   int ativos = (InpUsarDelta ? 1 : 0) + (InpUsarFita ? 1 : 0) +
                (InpUsarVP ? 1 : 0) + (InpUsarAgressao ? 1 : 0);
   if(InpVotosMin < 1 || InpVotosMin > ativos)
   {
      PrintFormat("InpVotosMin (%d) precisa ficar entre 1 e %d (votos ativos)", InpVotosMin, ativos);
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpStopPoints <= 0 || InpTakePoints <= 0 || InpVotoValidade < 1 ||
      InpValidade3 < 1 || InpValidade4 < 1 || InpDistancia < 0)
   {
      Print("Stop, alvo e validades devem ser > 0 e distancia >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(Minutos(InpInicio) >= Minutos(InpFimEntradas) && InpUseTimeFilter)
   {
      Print("Horario de inicio precisa ser antes do fim das entradas");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpTakePoints < InpStopPoints)
      PrintFormat("Atencao: stop %d x alvo %d exige acerto acima de %.1f%% para empatar",
                  InpStopPoints, InpTakePoints,
                  100.0 * InpStopPoints / (InpStopPoints + InpTakePoints));

   if(InpUsarDelta && !D_UsarDivergencia && !D_UsarAbsorcao)
   {
      Print("Delta ligado sem nenhum sinal interno (divergencia/absorcao)");
      return INIT_PARAMETERS_INCORRECT;
   }

   fitaSinaisAtivos = (F_UsarGrandes ? 1 : 0) + (F_UsarVelocidade ? 1 : 0) + (F_UsarDesequil ? 1 : 0);
   if(InpUsarFita && (F_MinSinais < 1 || F_MinSinais > fitaSinaisAtivos))
   {
      PrintFormat("F_MinSinais (%d) precisa ficar entre 1 e %d (sinais da Fita ativos)",
                  F_MinSinais, fitaSinaisAtivos);
      return INIT_PARAMETERS_INCORRECT;
   }

   if(C_JanelaMin < 5 || C_Pts <= 0 || C_Reversoes < 1 || C_HoldMin < 0 || V_ChopFator < 1.0)
   {
      Print("Parametros do modo cauteloso invalidos");
      return INIT_PARAMETERS_INCORRECT;
   }

   if((InpUsarDelta && D_FiltroTend) || (InpUsarFita && F_FiltroTend))
   {
      hMA = iMA(_Symbol, T_TF, T_Periodo, 0, T_Metodo, PRICE_CLOSE);
      if(hMA == INVALID_HANDLE) { Print("Falha ao criar a media"); return INIT_FAILED; }
   }
   if(InpUsarVP)
   {
      hATR = iATR(_Symbol, PERIOD_M1, 14);
      if(hATR == INVALID_HANDLE) { Print("Falha ao criar o ATR"); return INIT_FAILED; }
   }

   //--- Delta
   dCacheSize = D_Lookback + D_PivotK + 5;
   ArrayResize(dBar, dCacheSize);
   ArrayResize(dCum, dCacheSize);
   ArrayResize(dTime, dCacheSize);
   ArrayInitialize(dBar, 0);
   ArrayInitialize(dCum, 0);
   for(int i = 0; i < dCacheSize; i++) dTime[i] = 0;

   //--- Fita
   baseN = MathMax(F_JanelaBaseSeg, 60);
   ArrayResize(baseSeg, baseN);
   ArrayInitialize(baseSeg, 0);
   acumHistN = MathMax(F_AcumJanelaSeg, 10);
   ArrayResize(acumHist, acumHistN);
   ArrayInitialize(acumHist, 0);

   for(int v = 0; v < NVOTOS; v++) { votos[v].dir = 0; votos[v].barra = 0; }

   //--- painel: no testador sem modo visual nao ha grafico para desenhar
   painelAtivo = InpMostrarPainel &&
                 !(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE));
   if(painelAtivo) AtualizarPainel(true);

   PrintFormat("Consenso: %d de %d votos | limite %s (dist %d) | validade %d/%d barras | stop %d | alvo %d",
               InpVotosMin, ativos,
               InpModoPreco == PRECO_FECHAMENTO ? "no FECHAMENTO" : "na MAX/MIN",
               InpDistancia, InpValidade3, InpValidade4, InpStopPoints, InpTakePoints);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hMA  != INVALID_HANDLE) IndicatorRelease(hMA);
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   ObjectsDeleteAll(0, PFX);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
//| UTILITARIOS                                                      |
//+------------------------------------------------------------------+
double TickSz()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   return (t > 0.0) ? t : _Point;
}

double NormalizePrice(double p)
{
   double t = TickSz();
   return NormalizeDouble(MathRound(p / t) * t, _Digits);
}

double CalcLots()
{
   double mn = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double mx = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double st = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(st <= 0.0) st = 1.0;
   double l = MathFloor(InpLots / st + 1e-9) * st;
   return NormalizeDouble(MathMax(mn, MathMin(mx, l)), (st >= 1.0) ? 0 : 2);
}

int Minutos(const string hhmm)
{
   string p[];
   if(StringSplit(hhmm, ':', p) != 2) return 0;
   return (int)StringToInteger(p[0]) * 60 + (int)StringToInteger(p[1]);
}

int MinutosAgora()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   return dt.hour * 60 + dt.min;
}

bool HorarioEntrada()
{
   if(!InpUseTimeFilter) return true;
   int m = MinutosAgora();
   return (m >= Minutos(InpInicio) && m < Minutos(InpFimEntradas));
}

datetime Dia(datetime t) { return t - (t % 86400); }

//--- direcao da posicao do EA: +1, -1 ou 0
int PosicaoDir(ulong &ticket)
{
   ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol ||
         PositionGetInteger(POSITION_MAGIC) != (long)InpMagic) continue;
      ticket = t;
      return (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

//--- direcao da ordem pendente do EA: +1, -1 ou 0 (deixa a ordem selecionada)
int OrdemDir(ulong &ticket)
{
   ticket = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol ||
         OrderGetInteger(ORDER_MAGIC) != (long)InpMagic) continue;
      ticket = t;
      ENUM_ORDER_TYPE tp = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      return (tp == ORDER_TYPE_BUY_LIMIT || tp == ORDER_TYPE_BUY) ? 1 : -1;
   }
   return 0;
}

void CancelarOrdens()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) == _Symbol &&
         OrderGetInteger(ORDER_MAGIC) == (long)InpMagic)
         trade.OrderDelete(t);
   }
   ordemBarra = 0;
}

//--- true se ficou zerado
bool Zerar()
{
   CancelarOrdens();
   ulong t;
   for(int i = 0; i < 3 && PosicaoDir(t) != 0; i++)
      if(!trade.PositionClose(t))
      {
         PrintFormat("Falha ao zerar: %u - %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
         break;
      }
   return (PosicaoDir(t) == 0);
}

int Tendencia()
{
   if(hMA == INVALID_HANDLE) return 0;
   double ma[];
   ArraySetAsSeries(ma, true);
   if(CopyBuffer(hMA, 0, 0, 1, ma) < 1 || ma[0] <= 0.0) return 0;
   double preco = iClose(_Symbol, T_TF, 0);
   if(preco <= 0.0) return 0;
   double dist = preco - ma[0];
   if(MathAbs(dist) < T_DistMin * _Point) return 0;
   return (dist > 0.0) ? 1 : -1;
}

void RegistrarVoto(int idx, int dir, datetime barra)
{
   if(dir == 0) return;
   bool repetido = (votos[idx].dir == dir && votos[idx].barra == barra);
   votos[idx].dir   = dir;
   votos[idx].barra = barra;
   if(InpLog && !repetido)
      PrintFormat("VOTO %s -> %s", NOMES[idx], dir > 0 ? "COMPRA" : "VENDA");
}

//--- voto ainda dentro da validade? (e do mesmo dia)
bool VotoValido(int idx)
{
   if(votos[idx].dir == 0 || votos[idx].barra == 0) return false;
   if(Dia(votos[idx].barra) != Dia(TimeCurrent())) return false;
   int idade = iBarShift(_Symbol, PERIOD_M1, votos[idx].barra);
   return (idade >= 0 && idade <= InpVotoValidade);
}

//+==================================================================+
//| MODO CAUTELOSO - mercado indo e voltando (VP e Fita)             |
//+==================================================================+
int ContarReversoes(const MqlRates &r[], int n, double limite)
{
   int dir = 0, rev = 0, iHi = 0, iLo = 0;
   double ext = 0.0, hi = 0.0, lo = 0.0;
   bool inicio = true;
   for(int i = 0; i < n; i++)
   {
      bool alta = (r[i].close >= r[i].open);
      for(int k = 0; k < 2; k++)
      {
         double p = (k == 0) ? (alta ? r[i].low : r[i].high) : (alta ? r[i].high : r[i].low);
         int idx = i * 2 + k;
         if(inicio) { hi = lo = p; iHi = iLo = idx; inicio = false; continue; }
         if(dir == 0)
         {
            if(p > hi) { hi = p; iHi = idx; }
            if(p < lo) { lo = p; iLo = idx; }
            if(hi - lo >= limite) { dir = (iHi > iLo) ? 1 : -1; ext = (dir > 0) ? hi : lo; }
         }
         else if(dir == 1)
         {
            if(p > ext) ext = p;
            else if(ext - p >= limite) { rev++; dir = -1; ext = p; }
         }
         else
         {
            if(p < ext) ext = p;
            else if(p - ext >= limite) { rev++; dir = 1; ext = p; }
         }
      }
   }
   return rev;
}

//--- relida uma vez por barra M1
bool ModoCauteloso()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t > 0 && t != chopUltBarra)
   {
      chopUltBarra = t;
      MqlRates r[];
      ArraySetAsSeries(r, false);
      int n = CopyRates(_Symbol, PERIOD_M1, 1, C_JanelaMin, r);
      if(n >= C_JanelaMin / 2 && ContarReversoes(r, n, C_Pts * _Point) >= C_Reversoes)
      {
         if(!chopAtivo && InpLog) Print("MODO CAUTELOSO ligado");
         chopAtivo = true;
         chopAte   = TimeCurrent() + C_HoldMin * 60;
      }
   }
   if(chopAtivo && TimeCurrent() >= chopAte)
   {
      chopAtivo = false;
      if(InpLog) Print("Modo cauteloso desligado");
   }
   return chopAtivo;
}

//+==================================================================+
//| VOTO 1 - DELTA_FLUXO                                             |
//+==================================================================+
long BarDelta(datetime barStart)
{
   MqlTick ticks[];
   ulong de  = (ulong)barStart * 1000;
   ulong ate = de + (ulong)PeriodSeconds(PERIOD_M1) * 1000 - 1;
   int n = CopyTicksRange(_Symbol, ticks, COPY_TICKS_TRADE, de, ate);
   if(n <= 0) return 0;
   long d = 0;
   for(int i = 0; i < n; i++)
   {
      bool c = (ticks[i].flags & TICK_FLAG_BUY)  != 0;
      bool s = (ticks[i].flags & TICK_FLAG_SELL) != 0;
      if(c == s) continue;
      long v = (long)ticks[i].volume;
      if(v <= 0) continue;
      d += c ? v : -v;
   }
   return d;
}

bool D_AtualizarCache()
{
   datetime t1 = iTime(_Symbol, PERIOD_M1, 1);
   if(t1 <= 0) return false;
   if(dTime[0] == t1) return true;

   if(dTime[0] == 0 || iBarShift(_Symbol, PERIOD_M1, dTime[0]) >= dCacheSize - 1)
   {
      for(int i = 0; i < dCacheSize; i++)
      {
         datetime bt = iTime(_Symbol, PERIOD_M1, i + 1);
         if(bt <= 0) return false;
         dTime[i] = bt;
         dBar[i]  = BarDelta(bt);
      }
   }
   else
   {
      int passos = iBarShift(_Symbol, PERIOD_M1, dTime[0]) - 1;
      if(passos < 1) passos = 1;
      for(int p = 0; p < passos; p++)
      {
         for(int i = dCacheSize - 1; i > 0; i--)
         {
            dBar[i]  = dBar[i - 1];
            dTime[i] = dTime[i - 1];
         }
         datetime bt = iTime(_Symbol, PERIOD_M1, passos - p);
         dTime[0] = bt;
         dBar[0]  = BarDelta(bt);
      }
   }

   long soma = 0;
   for(int i = dCacheSize - 1; i >= 0; i--) { soma += dBar[i]; dCum[i] = soma; }
   return true;
}

bool EhTopo(int s, int k)
{
   double h = iHigh(_Symbol, PERIOD_M1, s);
   for(int j = 1; j <= k; j++)
   {
      if(iHigh(_Symbol, PERIOD_M1, s - j) >= h) return false;
      if(iHigh(_Symbol, PERIOD_M1, s + j) >  h) return false;
   }
   return true;
}

bool EhFundo(int s, int k)
{
   double l = iLow(_Symbol, PERIOD_M1, s);
   for(int j = 1; j <= k; j++)
   {
      if(iLow(_Symbol, PERIOD_M1, s - j) <= l) return false;
      if(iLow(_Symbol, PERIOD_M1, s + j) >= l) return false;
   }
   return true;
}

bool DoisPivos(bool topo, int &r, int &a)
{
   r = a = -1;
   for(int s = D_PivotK + 1; s <= D_Lookback; s++)
   {
      if(topo ? !EhTopo(s, D_PivotK) : !EhFundo(s, D_PivotK)) continue;
      if(r < 0) r = s;
      else { a = s; return true; }
   }
   return false;
}

//--- devolve a direcao e a hora do pivo; NAO marca o pivo como usado
int D_Divergencia(datetime &pivo)
{
   int r, a;
   pivo = 0;
   if(DoisPivos(true, r, a) && r <= D_MaxPivotAge + D_PivotK)
   {
      bool precoSubiu = (iHigh(_Symbol, PERIOD_M1, r) - iHigh(_Symbol, PERIOD_M1, a)) >= D_MinPriceDiff * _Point;
      bool deltaCaiu  = (dCum[a - 1] - dCum[r - 1]) >= D_MinDeltaDiff;
      datetime tp = iTime(_Symbol, PERIOD_M1, r);
      if(precoSubiu && deltaCaiu && tp != ultimoPivoTopo) { pivo = tp; return -1; }
   }
   if(DoisPivos(false, r, a) && r <= D_MaxPivotAge + D_PivotK)
   {
      bool precoCaiu  = (iLow(_Symbol, PERIOD_M1, a) - iLow(_Symbol, PERIOD_M1, r)) >= D_MinPriceDiff * _Point;
      bool deltaSubiu = (dCum[r - 1] - dCum[a - 1]) >= D_MinDeltaDiff;
      datetime tf = iTime(_Symbol, PERIOD_M1, r);
      if(precoCaiu && deltaSubiu && tf != ultimoPivoFundo) { pivo = tf; return 1; }
   }
   return 0;
}

int D_Absorcao()
{
   long   d     = dBar[0];
   double range = iHigh(_Symbol, PERIOD_M1, 1) - iLow(_Symbol, PERIOD_M1, 1);
   if(MathAbs(d) < D_DeltaMinimo || range > D_RangeMaximo * _Point) return 0;
   return (d > 0) ? -1 : 1;   // entra contra quem agrediu
}

int VotoDelta()
{
   if(!D_AtualizarCache()) { leitura[0] = "sem dados"; return 0; }
   leitura[0] = StringFormat("delta %+d | range %.0f", (int)dBar[0],
                             (iHigh(_Symbol, PERIOD_M1, 1) - iLow(_Symbol, PERIOD_M1, 1)) / _Point);
   datetime pivo = 0;
   int sDiv = D_UsarDivergencia ? D_Divergencia(pivo) : 0;
   int sAbs = D_UsarAbsorcao    ? D_Absorcao()        : 0;
   if(sDiv == 0 && sAbs == 0) return 0;
   if(sDiv != 0 && sAbs != 0 && sDiv != sAbs) return 0;
   int dir = (sDiv != 0) ? sDiv : sAbs;
   if(D_FiltroTend && Tendencia() != dir) return 0;

   //--- so agora, com o voto saindo de fato, a divergencia e consumida
   if(sDiv < 0) ultimoPivoTopo  = pivo;
   if(sDiv > 0) ultimoPivoFundo = pivo;
   return dir;
}

//+==================================================================+
//| VOTO 2 - FITA (avaliada a cada segundo)                          |
//+==================================================================+
struct TapeStats
{
   bool valido;
   int  negocios;
   long volCompra, volVenda, volNeutro, volGrandesLiq;
};

bool LoteValido(long v) { return v > 0 && !(F_LoteTeto > 0 && v > F_LoteTeto); }

int LadoAgressor(const MqlTick &t, double &ultPreco)
{
   bool c = (t.flags & TICK_FLAG_BUY)  != 0;
   bool s = (t.flags & TICK_FLAG_SELL) != 0;
   int lado = 0;
   if(c != s) lado = c ? 1 : -1;
   else if(t.last > 0.0)
   {
      if(t.ask > 0.0 && t.last >= t.ask)            lado =  1;
      else if(t.bid > 0.0 && t.last <= t.bid)       lado = -1;
      else if(ultPreco > 0.0 && t.last > ultPreco)  lado =  1;
      else if(ultPreco > 0.0 && t.last < ultPreco)  lado = -1;
   }
   if(t.last > 0.0) ultPreco = t.last;
   return lado;
}

int ContarNegocios(ulong de, ulong ate)
{
   MqlTick tk[];
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   int c = 0;
   for(int i = 0; i < n; i++) if(LoteValido((long)tk[i].volume)) c++;
   return c;
}

void F_AtualizarBase(ulong agoraMs)
{
   ulong seg = agoraMs / 1000;
   if(seg == 0) return;
   seg -= 1;                                   // so segundos fechados
   if(baseUltSeg == 0) { baseUltSeg = seg; return; }
   if(seg <= baseUltSeg) return;
   if(seg - baseUltSeg >= (ulong)MathMin(baseN, 120))
   {
      ArrayInitialize(baseSeg, 0);
      baseTotal = 0; baseCheios = 0; baseUltSeg = seg;
      return;
   }
   for(ulong s = baseUltSeg + 1; s <= seg; s++)
   {
      int idx = (int)(s % (ulong)baseN);
      baseTotal -= baseSeg[idx];
      baseSeg[idx] = ContarNegocios(s * 1000, s * 1000 + 999);
      baseTotal += baseSeg[idx];
      if(baseCheios < baseN) baseCheios++;
   }
   baseUltSeg = seg;
}

long DeltaNoIntervalo(ulong de, ulong ate)
{
   if(ate <= de) return 0;
   MqlTick tk[];
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   long d = 0;
   double ult = 0.0;
   for(int i = 0; i < n; i++)
   {
      long v = (long)tk[i].volume;
      if(!LoteValido(v)) continue;
      d += LadoAgressor(tk[i], ult) * v;
   }
   return d;
}

void F_AtualizarAcumulado(ulong agoraMs)
{
   if(!F_UsarAcumulado || agoraMs == 0) return;
   datetime hoje = iTime(_Symbol, PERIOD_D1, 0);
   if(hoje != diaDoAcum) { diaDoAcum = hoje; acumAteMs = 0; deltaAcum = 0; }
   ulong ate = agoraMs - 1;
   if(acumAteMs == 0)
   {
      ulong ini = (hoje > 0) ? (ulong)hoje * 1000 : ate;
      deltaAcum = (ini < ate) ? DeltaNoIntervalo(ini, ate) : 0;
      acumAteMs = ate;
      return;
   }
   if(ate > acumAteMs) { deltaAcum += DeltaNoIntervalo(acumAteMs + 1, ate); acumAteMs = ate; }

   ulong seg = ate / 1000;
   if(seg <= acumHistSeg) return;
   if(acumHistSeg > 0 && seg - acumHistSeg >= (ulong)acumHistN)
   {
      ArrayInitialize(acumHist, 0);
      acumHistCheios = 0;
   }
   int idx = (int)(seg % (ulong)acumHistN);
   long antigo = acumHist[idx];
   acumHist[idx] = deltaAcum;
   if(acumHistCheios >= acumHistN) acumVariacao = deltaAcum - antigo;
   else { acumHistCheios++; acumVariacao = 0; }
   acumHistSeg = seg;
}

int F_LadoAcumulado()
{
   if(!F_UsarAcumulado || acumHistCheios < acumHistN) return 0;
   if(MathAbs(acumVariacao) < F_AcumMinimo) return 0;
   return (acumVariacao > 0) ? 1 : -1;
}

TapeStats LerFita(ulong fimMs)
{
   TapeStats t;
   t.valido = false; t.negocios = 0;
   t.volCompra = t.volVenda = t.volNeutro = t.volGrandesLiq = 0;
   ulong ini = (fimMs > (ulong)F_JanelaSeg * 1000) ? fimMs - (ulong)F_JanelaSeg * 1000 : 0;
   MqlTick tk[];
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, ini, fimMs);
   double ult = 0.0;
   for(int i = 0; i < n; i++)
   {
      long v = (long)tk[i].volume;
      if(!LoteValido(v)) continue;
      int lado = LadoAgressor(tk[i], ult);
      t.negocios++;
      if(lado > 0) t.volCompra += v; else if(lado < 0) t.volVenda += v; else t.volNeutro += v;
      if(v >= F_LoteGrande && lado != 0) t.volGrandesLiq += lado * v;
   }
   t.valido = (t.negocios > 0);
   return t;
}

int VotoFita(ulong agoraMs)
{
   //--- acumulado e base andam sempre, mesmo sem sinal, para nao defasar
   F_AtualizarAcumulado(agoraMs);
   F_AtualizarBase(agoraMs);

   TapeStats t = LerFita(agoraMs);
   if(!t.valido || t.negocios < F_MinNegocios)
   {
      leitura[1] = StringFormat("fita rala (%d negocios em %ds)", t.negocios, F_JanelaSeg);
      return 0;
   }
   long total = t.volCompra + t.volVenda + t.volNeutro;
   if(total <= 0) return 0;
   double saldo = (double)(t.volCompra - t.volVenda) / total;

   int s1 = 0, s2 = 0, s3 = 0;
   if(F_UsarGrandes && MathAbs(t.volGrandesLiq) >= F_VolGrandesMin)
      s1 = (t.volGrandesLiq > 0) ? 1 : -1;

   double velBase = (baseCheios > 0) ? (double)baseTotal / baseCheios : 0.0;
   double fator   = (velBase > 0.0) ? ((double)t.negocios / F_JanelaSeg) / velBase : 0.0;
   if(F_UsarVelocidade && baseCheios >= F_JanelaSeg * 4 &&
      fator >= F_FatorVelocidade && MathAbs(saldo) >= 0.20)
      s2 = (saldo > 0) ? 1 : -1;

   leitura[1] = StringFormat("saldo %+.0f%% | vel %.1fx | grandes %+d",
                             saldo * 100.0, fator, (int)t.volGrandesLiq);

   if(F_UsarDesequil && total >= F_VolMinJanela && MathAbs(saldo) >= F_DesequilMin)
      s3 = (saldo > 0) ? 1 : -1;

   int compras = (s1 > 0 ? 1 : 0) + (s2 > 0 ? 1 : 0) + (s3 > 0 ? 1 : 0);
   int vendas  = (s1 < 0 ? 1 : 0) + (s2 < 0 ? 1 : 0) + (s3 < 0 ? 1 : 0);
   if(compras > 0 && vendas > 0) return 0;

   //--- mercado indo e voltando: exige mais sinais concordando
   int minSinais = F_MinSinais;
   if(F_UsarChop && ModoCauteloso())
      minSinais = MathMin(MathMax(F_ChopMinSinais, F_MinSinais), fitaSinaisAtivos);

   int dir = 0;
   if(compras >= minSinais) dir = 1;
   else if(vendas >= minSinais) dir = -1;
   if(dir == 0) return 0;

   int concordam = (dir > 0) ? compras : vendas;
   bool ignoraTend = (F_SinaisIgnoraTend > 0 && concordam >= F_SinaisIgnoraTend);
   if(F_FiltroTend && !ignoraTend && Tendencia() != dir) return 0;

   int acum = F_LadoAcumulado();
   if(acum != 0 && acum != dir) return 0;
   return dir;
}

//+==================================================================+
//| VOTO 3 - VP_BREAKOUT                                             |
//+==================================================================+
bool CalcProfile(double &vah, double &val)
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int n = CopyRates(_Symbol, PERIOD_M1, 1, V_ProfileBars, r);
   if(n < V_ProfileBars / 2) return false;

   double lo = r[0].low, hi = r[0].high;
   for(int i = 1; i < n; i++) { lo = MathMin(lo, r[i].low); hi = MathMax(hi, r[i].high); }
   if(hi - lo <= 0.0) return false;

   double bin = (hi - lo) / V_Bins;
   double vol[];
   ArrayResize(vol, V_Bins);
   ArrayInitialize(vol, 0.0);

   for(int i = 0; i < n; i++)
   {
      double v = V_UseTickVolume ? (double)r[i].tick_volume : (double)r[i].real_volume;
      if(v <= 0.0) v = (double)r[i].tick_volume;
      if(v <= 0.0) continue;
      double br = r[i].high - r[i].low;
      int f = (int)MathFloor((r[i].low  - lo) / bin);
      int l = (int)MathFloor((r[i].high - lo) / bin);
      f = (int)MathMin(MathMax(f, 0), V_Bins - 1);
      l = (int)MathMin(MathMax(l, 0), V_Bins - 1);
      if(br <= 0.0) { vol[f] += v; continue; }
      for(int b = f; b <= l; b++)
      {
         double bl = lo + b * bin;
         double ov = MathMin(bl + bin, r[i].high) - MathMax(bl, r[i].low);
         if(ov > 0.0) vol[b] += v * (ov / br);
      }
   }

   int poc = 0;
   double tot = 0.0;
   for(int b = 0; b < V_Bins; b++) { tot += vol[b]; if(vol[b] > vol[poc]) poc = b; }
   if(tot <= 0.0) return false;

   double alvo = tot * V_ValueAreaPct / 100.0, acc = vol[poc];
   int up = poc, dn = poc;
   while(acc < alvo && (up < V_Bins - 1 || dn > 0))
   {
      double vu = (up < V_Bins - 1) ? vol[up + 1] : -1.0;
      double vd = (dn > 0) ? vol[dn - 1] : -1.0;
      if(vu >= vd && vu >= 0.0) { up++; acc += vol[up]; }
      else if(vd >= 0.0)        { dn--; acc += vol[dn]; }
      else break;
   }
   vah = lo + (up + 1) * bin;
   val = lo + dn * bin;
   return true;
}

int VotoVP()
{
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(hATR, 0, 1, 1, atr) < 1 || atr[0] <= 0.0) { leitura[2] = "sem ATR"; return 0; }

   double vah, val;
   if(!CalcProfile(vah, val)) { leitura[2] = "historico insuficiente"; return 0; }
   if(vah - val < V_MinVAWidthATR * atr[0])
   {
      leitura[2] = StringFormat("VA estreita (%.0f pts)", (vah - val) / _Point);
      return 0;
   }

   bool caut = V_UsarChop && ModoCauteloso();
   double buffer = V_BreakBufferATR * atr[0] * (caut ? V_ChopFator : 1.0);
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   leitura[2] = StringFormat("VAL %.0f | VAH %.0f", val, vah);
   if(c1 > vah + buffer) return 1;
   if(c1 < val - buffer) return -1;
   return 0;
}

//+==================================================================+
//| VOTO 4 - AGRESSAO                                                |
//+==================================================================+
double VolTick(const MqlTick &t) { return (t.volume_real > 0) ? t.volume_real : (double)t.volume; }
double VolBar(const MqlRates &r) { return (r.real_volume > 0) ? (double)r.real_volume : (double)r.tick_volume; }

int VotoAgressao()
{
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(_Symbol, PERIOD_M1, 1, A_MediaN + 1, r) < A_MediaN + 1) return 0;
   double soma = 0;
   for(int k = 1; k <= A_MediaN; k++) soma += VolBar(r[k]);
   double volNormal = soma / A_MediaN;
   if(volNormal <= 0) return 0;

   MqlTick tk[];
   ulong de  = (ulong)r[0].time * 1000;
   ulong ate = (ulong)(r[0].time + 60) * 1000 - 1;
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE, de, ate);
   if(n < 2) { leitura[3] = "sem negocios na barra"; return 0; }

   bool temFlags = false;
   for(int i = 0; i < n && !temFlags; i++)
      if((tk[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0) temFlags = true;

   int lado[];
   ArrayResize(lado, n);
   int ultimo = 0;
   for(int i = 0; i < n; i++)
   {
      int l = 0;
      if(temFlags)
      {
         bool b = (tk[i].flags & TICK_FLAG_BUY) != 0;
         bool s = (tk[i].flags & TICK_FLAG_SELL) != 0;
         l = (b && !s) ? 1 : (s && !b) ? -1 : 0;
      }
      else if(i > 0)
      {
         l = (tk[i].last > tk[i-1].last) ? 1 : (tk[i].last < tk[i-1].last) ? -1 : ultimo;
         ultimo = l;
      }
      lado[i] = l;
   }

   double volJanela = volNormal * A_JanelaSeg / 60.0;
   double niveis = A_NiveisMin * TickSz();
   long   janMs = (long)A_JanelaSeg * 1000;
   int    melhorDir = 0;
   long   melhorFim = -1;
   double melhorIni = 0;
   int    fim = 0;
   double vc = 0, vv = 0;
   double pico = 0;   // maior volume de janela / volume normal da janela

   for(int ini = 0; ini < n; ini++)
   {
      if(fim < ini) { fim = ini; vc = 0; vv = 0; }
      while(fim < n && tk[fim].time_msc - tk[ini].time_msc <= janMs)
      {
         double v = VolTick(tk[fim]);
         if(lado[fim] > 0) vc += v;
         if(lado[fim] < 0) vv += v;
         fim++;
      }
      double total = vc + vv;
      if(volJanela > 0 && total / volJanela > pico) pico = total / volJanela;
      if(total > 0 && total >= A_FatorVolume * volJanela)
      {
         double p0 = tk[ini].last, mx = p0, mn = p0;
         for(int k = ini; k < fim; k++) { mx = MathMax(mx, tk[k].last); mn = MathMin(mn, tk[k].last); }
         int dir = 0;
         if(vc >= A_DominioPct / 100.0 * total && mx - p0 >= niveis - TickSz() / 2) dir = 1;
         else if(vv >= A_DominioPct / 100.0 * total && p0 - mn >= niveis - TickSz() / 2) dir = -1;
         if(dir != 0 && (long)tk[fim - 1].time_msc > melhorFim)
         {
            melhorDir = dir; melhorFim = (long)tk[fim - 1].time_msc; melhorIni = p0;
         }
      }
      double v0 = VolTick(tk[ini]);
      if(lado[ini] > 0) vc -= v0;
      if(lado[ini] < 0) vv -= v0;
   }

   leitura[3] = StringFormat("pico %.1fx do volume (precisa %.1fx)", pico, A_FatorVolume);
   if(melhorDir == 0) return 0;
   if(A_ExigirSustentar)
   {
      if(melhorDir > 0 && r[0].close <= melhorIni) return 0;
      if(melhorDir < 0 && r[0].close >= melhorIni) return 0;
   }
   return melhorDir;
}

//+==================================================================+
//| ORDEM                                                            |
//+==================================================================+
bool EnviarLimite(int dir, int nVotos)
{
   double c1 = iClose(_Symbol, PERIOD_M1, 1);
   double h1 = iHigh(_Symbol,  PERIOD_M1, 1);
   double l1 = iLow(_Symbol,   PERIOD_M1, 1);
   if(c1 <= 0.0) return false;

   double preco;
   //--- compra sempre ABAIXO da referencia, venda sempre ACIMA
   if(InpModoPreco == PRECO_FECHAMENTO)
      preco = (dir > 0) ? c1 - InpDistancia * _Point : c1 + InpDistancia * _Point;
   else
      preco = (dir > 0) ? l1 - InpDistancia * _Point : h1 + InpDistancia * _Point;
   preco = NormalizePrice(preco);

   double stop = NormalizePrice(preco - dir * InpStopPoints * _Point);
   double alvo = NormalizePrice(preco + dir * InpTakePoints * _Point);
   double lots = CalcLots();
   int    valid = (nVotos >= 4) ? InpValidade4 : InpValidade3;
   string cmt  = StringFormat("Consenso %d votos", nVotos);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0 || ask < bid)
   {
      PrintFormat("Cotacao indisponivel (ask=%.0f bid=%.0f) - ordem ignorada", ask, bid);
      return false;
   }

   bool ok, mercado = false;
   //--- preco ja passou do limite: na B3 a limite executaria na hora,
   //--- mas o MT5 recusa BuyLimit acima do ask. Entra a mercado.
   if(dir > 0 && ask <= preco)
   {
      mercado = true;
      ok = trade.Buy(lots, _Symbol, 0.0, NormalizePrice(ask - InpStopPoints * _Point),
                     NormalizePrice(ask + InpTakePoints * _Point), cmt);
   }
   else if(dir < 0 && bid >= preco)
   {
      mercado = true;
      ok = trade.Sell(lots, _Symbol, 0.0, NormalizePrice(bid + InpStopPoints * _Point),
                      NormalizePrice(bid - InpTakePoints * _Point), cmt);
   }
   else
      ok = (dir > 0) ? trade.BuyLimit (lots, preco, _Symbol, stop, alvo, tipoValidade, 0, cmt)
                     : trade.SellLimit(lots, preco, _Symbol, stop, alvo, tipoValidade, 0, cmt);

   uint rc = trade.ResultRetcode();
   if(!ok || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_PLACED && rc != TRADE_RETCODE_DONE_PARTIAL))
   {
      PrintFormat("Falha na ordem: %u - %s", rc, trade.ResultRetcodeDescription());
      return false;
   }

   if(mercado)
   {
      ordemBarra = 0;
      if(InpLog)
         PrintFormat(">>> %s A MERCADO (preco ja alem da limite %.0f) | %d votos",
                     dir > 0 ? "COMPRA" : "VENDA", preco, nVotos);
   }
   else
   {
      ordemBarra = iTime(_Symbol, PERIOD_M1, 0);
      ordemValid = valid;
      if(InpLog)
         PrintFormat(">>> %s LIMITE em %.0f | %d votos | validade %d barras | SL %.0f | TP %.0f",
                     dir > 0 ? "COMPRA" : "VENDA", preco, nVotos, valid, stop, alvo);
   }
   return true;
}

void CancelarVencida()
{
   ulong t;
   if(OrdemDir(t) == 0) { ordemBarra = 0; return; }
   if(ordemBarra == 0)
   {
      //--- ordem de antes de recarregar o EA: usa a hora de criacao
      ordemBarra = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      ordemValid = InpValidade3;
   }
   int barras = Bars(_Symbol, PERIOD_M1, ordemBarra, TimeCurrent()) - 1;
   if(barras >= ordemValid)
   {
      if(trade.OrderDelete(t))
      {
         ordemBarra = 0;
         if(InpLog) PrintFormat("Limite cancelada: %d barras sem execucao", ordemValid);
      }
   }
}

void MarcarConsenso(int dir, datetime chave) { consDir = dir; consChave = chave; }

//+==================================================================+
//| ESTADO DE CADA ROBO - painel e log                               |
//+==================================================================+
bool VotoAtivo(int v)
{
   switch(v)
   {
      case 0: return InpUsarDelta;
      case 1: return InpUsarFita;
      case 2: return InpUsarVP;
      case 3: return InpUsarAgressao;
   }
   return false;
}

string EstadoVoto(int v)
{
   if(!VotoAtivo(v))  return "DESLIGADO";
   if(!VotoValido(v)) return "SEM SINAL";
   return (votos[v].dir > 0) ? "COMPRADO" : "VENDIDO";
}

//--- uma linha no log sempre que o quadro de votos muda
void LogResumo(int compras, int vendas)
{
   if(!InpLog) return;
   static string anterior = "";
   string s = "";
   for(int v = 0; v < NVOTOS; v++)
   {
      if(!VotoAtivo(v)) continue;
      if(s != "") s += " | ";
      s += NOMES[v] + " " + EstadoVoto(v);
   }
   s += StringFormat("  =>  compra %d x %d venda", compras, vendas);
   if(s == anterior) return;
   anterior = s;
   Print("VOTOS: ", s);
}

void Rotulo(string id, int x, int y, string txt, color cor, int tam = 9)
{
   string nome = PFX + id;
   if(ObjectFind(0, nome) < 0)
   {
      ObjectCreate(0, nome, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nome, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nome, OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0, nome, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nome, OBJPROP_HIDDEN, true);
      ObjectSetString(0, nome, OBJPROP_FONT, "Consolas");
   }
   ObjectSetInteger(0, nome, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nome, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nome, OBJPROP_FONTSIZE, tam);
   ObjectSetInteger(0, nome, OBJPROP_COLOR, cor);
   ObjectSetString(0, nome, OBJPROP_TEXT, txt);
}

void Fundo(int x, int y, int larg, int alt)
{
   string nome = PFX + "fundo";
   if(ObjectFind(0, nome) < 0)
   {
      ObjectCreate(0, nome, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, nome, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, nome, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, nome, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, nome, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, nome, OBJPROP_BACK, false);
   }
   ObjectSetInteger(0, nome, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, nome, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, nome, OBJPROP_XSIZE, larg);
   ObjectSetInteger(0, nome, OBJPROP_YSIZE, alt);
   ObjectSetInteger(0, nome, OBJPROP_BGCOLOR, InpCorFundo);
   ObjectSetInteger(0, nome, OBJPROP_COLOR, InpCorTexto);
}

//+------------------------------------------------------------------+
//|  CONSENSO WIN                                                    |
//|  Delta      COMPRADO   (vale +2)                                 |
//|  Fita       VENDIDO    (vale +3)                                 |
//|  VP         SEM SINAL                                            |
//|  Agressao   COMPRADO   (ultima barra)                            |
//|  Compra 2 x 1 Venda  (precisa 3)                                 |
//|  AGUARDANDO CONSENSO                                             |
//+------------------------------------------------------------------+
void AtualizarPainel(bool forcar = false)
{
   if(!painelAtivo) return;

   //--- no maximo 1x por segundo, salvo quando algo acabou de mudar
   datetime agora = TimeCurrent();
   if(!forcar && agora == painelUltSeg) return;
   painelUltSeg = agora;

   int x = InpPainelX, y = InpPainelY, lh = 17;
   int alt = 34 + NVOTOS * lh + 4 * lh + 12;
   Fundo(x, y, 440, alt);
   Rotulo("tit", x + 10, y + 8, "CONSENSO WIN", InpCorTexto, 10);

   int compras = 0, vendas = 0;
   for(int v = 0; v < NVOTOS; v++)
   {
      int    yy  = y + 34 + v * lh;
      string est = EstadoVoto(v);
      string ext = "";
      color  cor = InpCorTexto;

      if(!VotoAtivo(v)) cor = clrDimGray;
      else if(VotoValido(v))
      {
         bool c = (votos[v].dir > 0);
         if(c) compras++; else vendas++;
         cor = c ? InpCorCompra : InpCorVenda;
         int resta = InpVotoValidade - iBarShift(_Symbol, PERIOD_M1, votos[v].barra);
         ext = (resta > 0) ? StringFormat("(vale +%d)", resta) : "(ultima)";
      }
      Rotulo("n" + IntegerToString(v), x + 10,  yy, NOMES[v], InpCorTexto);
      Rotulo("e" + IntegerToString(v), x + 95,  yy, est, cor);
      Rotulo("x" + IntegerToString(v), x + 165, yy, ext, InpCorTexto, 8);
      Rotulo("l" + IntegerToString(v), x + 235, yy, VotoAtivo(v) ? leitura[v] : "", clrGray, 8);
   }

   int   yb = y + 34 + NVOTOS * lh + 6;
   color cp = (compras >= InpVotosMin) ? InpCorCompra :
              (vendas  >= InpVotosMin) ? InpCorVenda  : InpCorTexto;
   Rotulo("placar", x + 10, yb,
          StringFormat("Compra %d x %d Venda   (precisa %d)", compras, vendas, InpVotosMin), cp);

   //--- status da operacao
   ulong  t;
   string st;
   color  cs  = InpCorTexto;
   int    pos = PosicaoDir(t);
   int    ord = (pos == 0) ? OrdemDir(t) : 0;
   if(pos != 0)
   {
      st = (pos > 0) ? "POSICAO COMPRADA" : "POSICAO VENDIDA";
      cs = (pos > 0) ? InpCorCompra : InpCorVenda;
   }
   else if(ord != 0)
   {
      int b = (ordemBarra > 0) ? Bars(_Symbol, PERIOD_M1, ordemBarra, TimeCurrent()) - 1 : 0;
      st = StringFormat("LIMITE DE %s  (barra %d de %d)",
                        ord > 0 ? "COMPRA" : "VENDA", b + 1, ordemValid);
      cs = (ord > 0) ? InpCorCompra : InpCorVenda;
   }
   else if(InpZerarFimDia && MinutosAgora() >= Minutos(InpZerar)) st = "ZERADO (FIM DO DIA)";
   else if(!HorarioEntrada())                                      st = "FORA DO HORARIO";
   else                                                            st = "AGUARDANDO CONSENSO";
   Rotulo("status", x + 10, yb + lh, st, cs);

   Rotulo("caut", x + 10, yb + 2 * lh,
          chopAtivo ? "Modo cauteloso LIGADO" : "Modo cauteloso desligado",
          chopAtivo ? clrGoldenrod : clrDimGray, 8);

   //--- dados: sem ticks de negocio, Delta/Fita/Agressao nao tem o que ler
   string dg;
   color  cd = clrDimGray;
   if(diagTicks < 0)
      dg = "Ticks: aguardando a primeira barra";
   else if(diagTicks == 0)
   {
      dg = "SEM TICKS DE NEGOCIO - Delta, Fita e Agressao parados";
      cd = InpCorVenda;
   }
   else if(diagFlagsPct < 50.0)
   {
      dg = StringFormat("Ticks: %d | so %.0f%% com agressor - Delta nao funciona", diagTicks, diagFlagsPct);
      cd = clrGoldenrod;
   }
   else
      dg = StringFormat("Ticks na ultima barra: %d | %.0f%% com agressor", diagTicks, diagFlagsPct);
   Rotulo("diag", x + 10, yb + 3 * lh, dg, cd, 8);

   ChartRedraw(0);
}

//--- confere se a barra que fechou trouxe negocios com lado agressor
void DiagnosticoTicks()
{
   datetime b1 = iTime(_Symbol, PERIOD_M1, 1);
   if(b1 <= 0) return;
   MqlTick tk[];
   int n = CopyTicksRange(_Symbol, tk, COPY_TICKS_TRADE,
                          (ulong)b1 * 1000, (ulong)(b1 + 60) * 1000 - 1);
   int comFlag = 0;
   for(int i = 0; i < n; i++)
      if((tk[i].flags & (TICK_FLAG_BUY | TICK_FLAG_SELL)) != 0) comFlag++;
   diagTicks    = MathMax(n, 0);
   diagFlagsPct = (n > 0) ? 100.0 * comFlag / n : 0.0;

   if(!avisoTicks && HorarioEntrada() && (n <= 0 || comFlag == 0))
   {
      avisoTicks = true;
      Print("ATENCAO: ", (n <= 0) ? "a barra nao tem ticks de negocio" : "os ticks nao trazem o lado agressor",
            ". Delta precisa do lado agressor; Fita e Agressao precisam dos negocios. ",
            "No testador use 'Cada tick com base em ticks reais'. ",
            "Em serie continua (WIN$, WIN$N) teste no contrato vigente.");
   }
}

//+==================================================================+
//| CONSENSO (a cada barra M1 nova)                                  |
//+==================================================================+
void NovaBarra()
{
   datetime b1 = iTime(_Symbol, PERIOD_M1, 1);
   DiagnosticoTicks();

   //--- votos das estrategias de barra, sobre a barra que fechou
   if(InpUsarDelta)    RegistrarVoto(0, VotoDelta(),    b1);
   if(InpUsarVP)       RegistrarVoto(2, VotoVP(),       b1);
   if(InpUsarAgressao) RegistrarVoto(3, VotoAgressao(), b1);

   CancelarVencida();

   //--- conta os votos validos
   int compras = 0, vendas = 0;
   for(int v = 0; v < NVOTOS; v++)
   {
      if(!VotoValido(v)) continue;
      if(votos[v].dir > 0) compras++; else vendas++;
   }
   LogResumo(compras, vendas);

   int dir = 0, n = 0;
   bool cBuy = (compras >= InpVotosMin), cSell = (vendas >= InpVotosMin);
   if(cBuy && cSell) return;                 // empate: nao opera
   if(cBuy)  { dir =  1; n = compras; }
   if(cSell) { dir = -1; n = vendas;  }
   if(dir == 0) return;

   //--- chave = voto mais novo do lado vencedor. Consenso com a mesma
   //--- chave ja foi tratado; so age quando entra voto novo.
   datetime chave = 0;
   for(int v = 0; v < NVOTOS; v++)
      if(VotoValido(v) && votos[v].dir == dir && votos[v].barra > chave)
         chave = votos[v].barra;
   if(dir == consDir && chave <= consChave) return;

   if(InpLog)
      PrintFormat("CONSENSO %s: %d votos (compra %d x venda %d)",
                  dir > 0 ? "COMPRA" : "VENDA", n, compras, vendas);

   ulong pt, ot;
   int pos = PosicaoDir(pt);

   if(pos == dir) { MarcarConsenso(dir, chave); return; }   // ja a favor: segue stop/alvo

   if(pos != 0)                                              // posicao contraria
   {
      if(!InpReverter) { MarcarConsenso(dir, chave); return; }
      if(InpLog) Print("REVERSAO: zerando posicao contraria");
      if(!Zerar()) return;                                   // tenta de novo na proxima barra
   }

   int ord = OrdemDir(ot);
   if(ord == dir) { MarcarConsenso(dir, chave); return; }    // limite do mesmo lado: mantem
   if(ord != 0) CancelarOrdens();                            // limite do outro lado: troca

   //--- zerar vale sempre; abrir, so no horario de entrada
   if(!HorarioEntrada()) { MarcarConsenso(dir, chave); return; }

   if(EnviarLimite(dir, n)) MarcarConsenso(dir, chave);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(InpZerarFimDia && MinutosAgora() >= Minutos(InpZerar))
   {
      ulong t, o;
      if(PosicaoDir(t) != 0 || OrdemDir(o) != 0) Zerar();
      AtualizarPainel();
      return;
   }

   //--- Fita: avaliada no maximo 1x por segundo
   if(InpUsarFita)
   {
      MqlTick agora;
      if(SymbolInfoTick(_Symbol, agora) && agora.time_msc > 0 &&
         agora.time_msc - ultimaAvaliacaoMs >= 1000)
      {
         ultimaAvaliacaoMs = agora.time_msc;
         RegistrarVoto(1, VotoFita(agora.time_msc), iTime(_Symbol, PERIOD_M1, 0));
      }
   }

   datetime b0 = iTime(_Symbol, PERIOD_M1, 0);
   if(b0 != lastBarTime)
   {
      lastBarTime = b0;
      NovaBarra();
      AtualizarPainel(true);
   }
   else
      AtualizarPainel();
}
//+------------------------------------------------------------------+
