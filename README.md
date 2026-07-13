# Clipboard Signal Trader (MT5)

A MetaTrader 5 Expert Advisor that turns **manually copied** trade signals (from
Telegram, Discord, or anywhere else) into orders — with a human in the loop at
every step. You copy a signal to the clipboard, click **Load**, review and edit
a proposed order table, and only then click **OK / Send**.

The EA never watches a channel and never fires on its own. Nothing reaches the
market without an explicit click.

> ⚠️ **Risk warning.** This software places real orders on whatever account it is
> attached to. Trading leveraged instruments carries a substantial risk of loss.
> This project is provided for **educational purposes**, with no warranty of any
> kind. **Always test on a demo account first.** Nothing here is financial advice.

---

## Why this design

Automated signal copiers usually parse a channel and trade blindly. Two things go
wrong: signal formats vary wildly (so parsers silently misread), and a bad parse
becomes a bad trade instantly. This EA separates the two concerns:

1. **Parsing only proposes.** The parser fills an editable table; it never trades.
2. **Validation runs on the edited values.** Geometry, symbol, price-sanity and
   broker stop-level checks all execute on what you see after your edits — not on
   the raw parse.

The result is fast copy/paste execution that still keeps you in control.

---

## Features

- **Clipboard input** via the Windows API — copy a signal anywhere, click Load.
- **Mechanical parser** that handles many real-world formats (see below): mixed
  case, emojis, `#` prefixes, entry ranges, missing colons, index typos, and
  duplicated pastes.
- **Editable order table** — one row per trade. Every value (entry, SL, TP, lot,
  direction, order type) is editable before you send.
- **Per-broker symbol maps** — three switchable slots (e.g. one broker names gold
  `XAUUSDs`, another `XAUUSD`).
- **Smart symbol resolution:** direct name → active map → broker suffix → 6-char
  prefix search (e.g. signal `BTCUSD` → broker `BTCUSDT`).
- **Order types:** market, limit and stop, with side checks (a Buy Limit must sit
  below the market, etc.).
- **Validation gate:** direction/geometry, entry-vs-market sanity, and broker
  `stops level` distance — each row is accepted or rejected with a clear message.
- **Optional trade adjustments:** reduce every TP toward entry by a fixed %, and/or
  widen the SL away from entry by a fixed % (more risk). Both default to 0 (no change).
- **Auto filling-mode** detection (FOK / IOC / Return) per symbol.

---

## How it works

```
Clipboard (Ctrl+C) → Load → Parser → Editable table → [ you edit ]
                                                          │
                                              OK / Send → Validation gate → Orders
```

The validation gate always runs on the **edited** values, so any correction you
make in the table is what gets checked and executed.

---

## Requirements

- **MetaTrader 5** (desktop terminal).
- **Windows.** Clipboard reading uses `user32.dll` / `kernel32.dll`, so the
  clipboard feature is Windows-only. (A Windows VPS works fine.)
- No internet permissions or WebRequest URLs are needed — the EA does not call any
  external service.

---

## Installation

1. Copy `ClipboardSignalTrader.mq5` into your terminal's
   `MQL5/Experts/` folder.
   (In MT5: **File → Open Data Folder**, then `MQL5\Experts`.)
2. Open the file in **MetaEditor** and press **F7** (or Compile).
3. In MT5, drag the EA onto any chart.
4. In the EA dialog, **Common** tab, enable **Allow DLL imports**. This is
   required for clipboard access; without it, Load reports that the DLL is blocked.
5. Configure the inputs (at minimum, pick the correct symbol map for your broker).

The chart symbol/timeframe does not matter — the EA trades whatever symbol the
signal specifies (after mapping), not the chart symbol.

---

## Usage

1. Copy a signal to the clipboard (`Ctrl+C`) from Telegram or anywhere.
2. Click **Load**. The parser fills the table and shows the resolved broker symbol.
3. Review the rows. Edit any cell as needed. Toggle **DIR** (BUY/SELL) or **TYPE**
   (MKT/LMT/STP) by clicking them. Untick rows you don't want.
4. **Duplicate a row:** click **Y/N** on an empty row to copy the nearest filled
   row above it — handy when a signal has 2 targets but you want a 3rd position.
5. Click **OK / Send**. Each ticked row is validated and sent, or reported with a
   specific reason if rejected.

---

## Settings reference

| Input | Default | Meaning |
|---|---|---|
| `InpDefaultLot` | `0.01` | Lot proposed for every trade. |
| `InpTPReducePct` | `0.0` | Reduce each TP toward entry by this % of the entry→TP distance. `0` = off. |
| `InpRiskIncreasePct` | `0.0` | Widen SL away from entry by this % of the entry→SL distance (more risk). `0` = off. |
| `InpMagicNumber` | `770001` | Magic number stamped on orders. |
| `InpDeviationPoints` | `20` | Max price deviation / slippage in points. |
| `InpMaxPriceDevPct` | `3.0` | Reject a row if entry is more than this % from the current market. |
| `InpSymbolSuffix` | `""` | Broker suffix tried when a symbol isn't found directly (e.g. `s`). |
| `InpActiveMap` | `Map 1` | Which symbol map slot is active. |
| `InpMap1 / 2 / 3` | see file | Symbol maps, format `SIGNAL=BROKER;...`. |
| `InpPanelX / Y` | `15 / 20` | Panel position on the chart. |

### The two trade adjustments

Both are applied when a signal is loaded, so the adjusted values appear in the
table and remain fully editable. They are symmetric: one pulls TP in, the other
pushes SL out, each by a percentage of that level's distance from entry.

- **`InpTPReducePct`** moves each TP closer to entry. Example: entry `4100`,
  TP `4130` (distance 30). At `10%` the new TP is `4100 + 30 × 0.9 = 4127`. For a
  SELL the TP moves up toward entry by the same rule.
- **`InpRiskIncreasePct`** moves SL further from entry (a wider stop = more risk).
  Example: entry `4100`, SL `4090` (distance 10). At `10%` the new SL is
  `4100 - 10 × 1.10 = 4089`. For a SELL the SL moves further above entry.

Formulas: `TP = entry + (TP - entry) × (1 - tp%/100)` and
`SL = entry + (SL - entry) × (1 + risk%/100)`. At `0` both leave the signal
untouched. Lot size is taken straight from `InpDefaultLot`.

---

## Supported signal formats

The parser is line-oriented and label-driven. Each format below is handled; the
description explains what makes it distinctive and how the parser reads it.

### 1. Symbol + direction + entry on one line

```
XAUUSD BUY 4051.50

TP 1 : 4075
TP 2 : 4120

SL : 4035
```

The symbol, direction and entry share the first line, with the entry as a bare
number right after `BUY`. Targets use an indexed label with spaces around the colon
(`TP 1 :`). The parser reads the entry as the number following the direction token,
and takes each TP/SL as the last number on its line, so the `1`/`2` in `TP 1`/`TP 2`
is ignored.

### 2. Word symbol, entry range, "SI" typo, no-space labels

```
Sell Gold @4112.5-4122.5

SI :4126.5

Tp1:4108.5
Tp2:4103
```

`Gold` is a word alias resolved through the symbol map (→ `XAUUSDs` on Quomarkets).
The entry is a **range** `@4112.5-4122.5`; the parser uses the midpoint (`4117.5`)
and notes it. `SI` is a common typo for `SL` and is accepted as a stop-loss label.
Labels are lowercase and glued to the value (`Tp1:4108.5`) — still parsed correctly.

### 3. Repeated bare `TP:` with annotations

```
USDCAD BUY @ 1.3810

TP: 1.3830 (scalper)
TP: 1.3860 (intraday)
TP: 1.3910 (swing)
SL: 1.3743
```

There are no TP indices — just three `TP:` lines. The parser collects them in order
as TP1/TP2/TP3. The trailing annotations `(scalper)` / `(intraday)` / `(swing)`
contain no digits and are ignored. Entry uses the `@ price` form. If the same block
is pasted twice, duplicate TP values are removed.

### 4. Futures-style symbol with a dash, explicit ENTRY label

```
OIL-AUG26 SELL

ENTRY @  68.99
SL:    69.54

TP1:  68.45
TP2:  67.85
TP3: 67.21
```

The symbol contains a dash (`OIL-AUG26`). Resolution tries the full name first, then
the part before the dash (`OIL`) against the map. Entry uses an `ENTRY @` label, and
the irregular spacing after each label is harmless because values are read as the
last number on the line.

### 5. Emoji-heavy with `#` prefixes and verbose labels

```
🚨 SIGNAL ALERT 🚨

🌐 #XAUUSD

📊 Trade Details: 📈 #SELL

⚪️ Entry Point: 4075
🔴 Stop Loss (SL): 4083

🟢 Take Profit 1 (TP1): 4072
🟢 Take Profit 2 (TP2): 4067
🟢 Take Profit 3 (TP3): 4059
```

Emojis are stripped during tokenising. The symbol carries a `#` prefix (`#XAUUSD`),
which is removed. Direction comes from `#SELL` (the `📈` emoji is not trusted — the
text wins). Labels are verbose (`Entry Point:`, `Stop Loss (SL):`,
`Take Profit 1 (TP1):`); the value is still the last number on each line. Note the
`SIGNAL` header does **not** get mistaken for the `SI` stop-loss label, because `SI`
is only matched as a standalone word.

### 6. Pending order — Buy Limit

```
US30 BUY-LIMIT  @52061
SL:  51876

TP1: 52227
TP2: 52424
TP3: 52723
```

`US30` maps to the broker's index symbol (e.g. `DJI30`). `BUY-LIMIT` sets the order
type to **limit**, and the `@` price becomes the pending entry. At send time the EA
checks the side is valid (a Buy Limit must sit below the current market).

### 7. Market order with ENTRY on its own line

```
US30 BUY

ENTRY @52838
SL:  52651

TP1:   52992
TP2:  53189
TP3:  53402
```

The direction line has no number, so entry is taken from the separate `ENTRY @` line.
This is a plain market `BUY` (no `LIMIT`/`STOP` keyword), so it executes at market.

### 8. No-colon labels and the `TPI` index typo

```
XAUUSD BUY LIMIT AT 4066
TPI 4090
TP2 4130
SL 4050
```

Labels have no colon at all (`TPI 4090`, `TP2 4130`, `SL 4050`). Because values are
read as the last number on the line, the index is skipped and the price is taken
correctly. `TPI` is a typo for `TP1` (letter I for digit 1) and is still recognised
as a target. `BUY LIMIT AT` sets a limit order with the entry after `AT`.

---

### Rules behind the parser

**Value extraction:** for a labelled line, the value is the **last number on the
line** — the price is always last, and any label index (`1`, `2`) precedes it. The
one pattern this can miss is a numeric annotation *after* the price
(`TP1 4099 (R:2)`); such a line would need a dedicated rule.

**Sanity backstop:** any SL/TP that lands outside `entry/3 … entry×3` is treated as a
parse error and the whole signal is rejected — this catches a label index being
grabbed as a value (e.g. a stray `TP = 2` against `entry = 4066`).

---

## Symbol mapping & resolution

Different brokers name the same instrument differently. Maps translate the signal's
name to your broker's name, format `SIGNAL=BROKER`, entries separated by `;`:

```
XAUUSD=XAUUSDs;GOLD=XAUUSDs;US30=DJI30;NAS100=NAS100
```

Resolution order for each symbol:

1. **Direct** — if the broker already has the signal's name, use it as-is.
2. **Active map** — otherwise translate via the selected map slot.
3. **Suffix** — otherwise try the name plus `InpSymbolSuffix`.
4. **6-char prefix** — otherwise search broker symbols starting with the first 6
   characters (`BTCUSD` → `BTCUSDT`), preferring the shortest match.

If none resolve, the row is rejected with a clear message rather than traded.

> Because *direct* comes first, if a broker exposes both a plain and a suffixed
> variant of the same name, the plain one wins and the map isn't consulted for it.
> If you ever need the opposite, map that specific symbol explicitly (the map is
> still tried before suffix/prefix).

---

## Validation rules (per row, at send time)

- **Geometry:** BUY requires `SL < entry < TP`; SELL requires `TP < entry < SL`.
- **Price sanity:** entry within `InpMaxPriceDevPct` of the current market.
- **Stops level:** SL and TP respect the broker's minimum stop distance.
- **Order side:** Buy Limit below market, Buy Stop above market (and vice versa).
- **Lot:** floored to the broker step and clamped to min/max.

---

## Limitations

- Windows-only clipboard (by design).
- Up to **5 rows** per signal (`MAXROWS` in the source).
- On-chart editable fields are functional but basic: click a cell, type, press
  Enter. This is a MetaTrader constraint, not a bug.
- The parser targets a finite set of known formats. New formats can be added — the
  extraction is plain string logic, no regex.

---

## Contributing

Issues and pull requests are welcome, especially additional real-world signal
formats (with a couple of BUY and SELL examples each). Please strip any private
tokens, account numbers, or channel identifiers from examples.

---

## License

Choose a license before publishing (e.g. MIT). Until a `LICENSE` file is added, all
rights are reserved by the author.

## Disclaimer

This project is not affiliated with MetaQuotes, Telegram, or any broker or signal
provider. Use at your own risk. The author accepts no liability for any financial
loss arising from its use.
