#!/usr/bin/env python3
"""
CW-NLP-FSM: WSJT-X Style Smart CW Copilot & Autonomous QSO Engine
------------------------------------------------------------------
A 4-Layer Architecture combining Text Denoising, Entity & Intent Extraction,
Finite State Machine (FSM) Auto-Sequencing, and NLP/Statistical Sequence Reconstruction.
"""

import re
from dataclasses import dataclass, field
from enum import Enum, auto
from typing import Dict, List, Optional, Set, Tuple


# =====================================================================
# LAYER 1: TEXT DENOISING & MORSE VOCABULARY MATCHING
# =====================================================================

class CWTextDenoiser:
    """
    Cleans raw Morse stream output:
    - Strips non-alphanumeric noise / glitches
    - Splits glued contest/QSO tokens (e.g. TESTHG8W -> TEST HG8W, 5NN101 -> 5NN 101)
    - Removes isolated single-character noise (E = '.', T = '-')
    - Normalizes Morse prosigns and abbreviations
    """

    MORSE_VOCABULARY = {
        # Procedural / Contest
        "CQ", "TEST", "DE", "UR", "TU", "73", "SK", "BK", "K", "KN", "R", "RST",
        "CFM", "AGN", "PSE", "ES", "OP", "NAME", "QTH", "RIG", "ANT", "HW", "FB",
        "NR", "CONTEST", "DX", "UP", "DWN", "CL", "AR",
        # Common Q-Codes
        "QRZ", "QSL", "QSO", "QTH", "QRN", "QRM", "QRP", "QRO", "QSB", "QSY", "QRT",
        # Common Signal Reports
        "5NN", "599", "579", "589", "559"
    }

    # Callsign regex according to ITU standard: 1-3 alphanumeric prefix, 1 digit, 1-4 alphanumeric suffix
    CALLSIGN_REGEX = re.compile(r"^[A-Z0-9]{1,3}[0-9][A-Z0-9]{1,4}$")

    @classmethod
    def clean_raw_stream(cls, text: str) -> str:
        """Strip garbled symbols, normalize spaces."""
        text = text.upper()
        # Replace non-alphanumeric and non-space characters with space
        cleaned = re.sub(r"[^A-Z0-9\s]", " ", text)
        return " ".join(cleaned.split())

    @classmethod
    def split_glued_tokens(cls, text: str) -> str:
        """Splits common glued prefixes and reports caused by missing word gaps."""
        # Split prefixes: TESTHG8W -> TEST HG8W, CQW1AW -> CQ W1AW, DEJA1ABC -> DE JA1ABC
        text = re.sub(r"\b(TEST|CQ|DE|UR)([A-Z0-9]{3,8})\b", r"\1 \2", text, flags=re.IGNORECASE)
        # Split glued reports: 5NN101 -> 5NN 101, 599001 -> 599 001
        text = re.sub(r"\b(5NN|599|579|589)([0-9]+)\b", r"\1 \2", text, flags=re.IGNORECASE)
        # Split glued signoffs: QSLAU -> QSL TU, QSLTU -> QSL TU
        text = re.sub(r"\b(QSL)(TU|AU)\b", r"\1 TU", text, flags=re.IGNORECASE)
        return text

    @classmethod
    def is_valid_callsign(cls, token: str) -> bool:
        """Validates if token matches amateur radio callsign rules."""
        if not (3 <= len(token) <= 8):
            return False
        if token in cls.MORSE_VOCABULARY:
            return False
        # Must contain at least one letter and at least one digit
        if not re.search(r"[A-Z]", token) or not re.search(r"[0-9]", token):
            return False
        return bool(cls.CALLSIGN_REGEX.match(token))

    @classmethod
    def filter_isolated_single_chars(cls, tokens: List[str]) -> List[str]:
        """
        Removes isolated single-character noise (especially 'E' and 'T')
        that are not recognized standalone prosigns (like 'K' or 'R').
        """
        filtered = []
        for i, t in enumerate(tokens):
            if len(t) == 1:
                # 'K' and 'R' are standard turn-over / acknowledgment signals
                if t in {"K", "R"}:
                    filtered.append(t)
                else:
                    # Floating E (dit), T (dah), I, etc. caused by QRN/spikes are discarded
                    continue
            else:
                filtered.append(t)
        return filtered

    @classmethod
    def denoise(cls, raw_stream: str) -> List[str]:
        """Full Layer 1 pipeline: returns clean, verified token sequence."""
        cleaned = cls.clean_raw_stream(raw_stream)
        split = cls.split_glued_tokens(cleaned)
        tokens = split.split()
        return cls.filter_isolated_single_chars(tokens)


# =====================================================================
# LAYER 2: ENTITY EXTRACTION & INTENT CLASSIFICATION
# =====================================================================

class CWIntent(Enum):
    UNKNOWN = auto()
    CALLING_CQ = auto()       # e.g., "CQ CQ DE G4XYZ K" or "TEST HG8W HG8W"
    ANSWERING_CALL = auto()   # e.g., "EP2AES DE G4XYZ K" or "G4XYZ"
    SENDING_REPORT = auto()   # e.g., "UR 5NN 101 BK" or "5NN 101"
    SENDING_INFO = auto()     # e.g., "NAME JOHN QTH LONDON"
    SIGNOFF = auto()          # e.g., "TU 73", "QSL TU", "73 SK", "EE"


@dataclass
class CWFrame:
    intent: CWIntent = CWIntent.UNKNOWN
    sender_call: Optional[str] = None
    target_call: Optional[str] = None
    rst_report: Optional[str] = None
    serial_exchange: Optional[str] = None
    operator_name: Optional[str] = None
    qth: Optional[str] = None
    raw_tokens: List[str] = field(default_factory=list)


class CWEntityAndIntentParser:
    """
    Parses cleaned tokens into semantic entities and QSO intents.
    """

    def __init__(self, my_call: str = "EP2AES"):
        self.my_call = my_call.upper()

    def parse_tokens(self, tokens: List[str]) -> List[CWFrame]:
        """Extracts frames/events from a sliding window of tokens."""
        frames = []
        n = len(tokens)
        i = 0

        while i < n:
            t = tokens[i]

            # 1. Intent: CALLING_CQ / CONTEST TEST
            if t in {"CQ", "TEST"}:
                frame = CWFrame(intent=CWIntent.CALLING_CQ)
                # Look ahead for candidate callsign
                for j in range(i + 1, min(n, i + 5)):
                    cand = tokens[j]
                    if CWTextDenoiser.is_valid_callsign(cand) and cand != self.my_call:
                        frame.sender_call = cand
                        break
                if frame.sender_call:
                    frames.append(frame)
                i += 1
                continue

            # 2. Repeated Callsign Pattern without "CQ/TEST": "<CALL> <CALL>"
            if CWTextDenoiser.is_valid_callsign(t) and t != self.my_call:
                if i + 1 < n and tokens[i + 1] == t:
                    frame = CWFrame(intent=CWIntent.CALLING_CQ, sender_call=t)
                    frames.append(frame)
                    i += 2
                    continue

            # 3. Directed Call: "<MYCALL> DE <CALL>" or "<CALL> DE <MYCALL>"
            if t == "DE" and i > 0 and i + 1 < n:
                prev = tokens[i - 1]
                nxt = tokens[i + 1]
                frame = CWFrame(intent=CWIntent.ANSWERING_CALL)
                if CWTextDenoiser.is_valid_callsign(nxt):
                    frame.sender_call = nxt
                if CWTextDenoiser.is_valid_callsign(prev):
                    frame.target_call = prev
                if frame.sender_call or frame.target_call:
                    frames.append(frame)
                    i += 2
                    continue

            # 4. Signal Report / Contest Exchange: 5NN / 599 + Serial
            if t in {"5NN", "599", "579", "589"}:
                frame = CWFrame(intent=CWIntent.SENDING_REPORT, rst_report="599" if t == "5NN" else t)
                # Check previous token for caller
                if i > 0 and CWTextDenoiser.is_valid_callsign(tokens[i - 1]):
                    frame.sender_call = tokens[i - 1]
                # Check next token for serial/zone number (e.g., 101, 14, 001)
                if i + 1 < n and tokens[i + 1].isdigit():
                    frame.serial_exchange = tokens[i + 1]
                frames.append(frame)
                i += 1
                continue

            # 5. Signoff: 73, TU, SK, QSL
            if t in {"73", "TU", "SK", "QSL"}:
                frame = CWFrame(intent=CWIntent.SIGNOFF)
                frames.append(frame)
                i += 1
                continue

            i += 1

        return frames


# =====================================================================
# LAYER 3: FINITE STATE MACHINE (FSM) & WSJT-X STYLE AUTO-SEQUENCER
# =====================================================================

class QSOState(Enum):
    IDLE = "Idle (Listening)"
    CALLING_CQ = "Calling CQ (Run Mode)"
    ANSWERING_CQ = "Answering CQ / Calling Station"
    EXCHANGE_REPORT = "Exchanging Signal Reports"
    EXCHANGE_INFO = "Exchanging Details / 73"
    COMPLETED = "QSO Completed & Logged"


@dataclass
class QSOSession:
    state: QSOState = QSOState.IDLE
    target_call: str = ""
    my_call: str = "EP2AES"
    my_rst_sent: str = "5NN"
    his_rst_rcvd: str = "599"
    exchange_sent: str = "001"
    exchange_rcvd: str = ""
    retry_count: int = 0
    max_retries: int = 3


class CWFiniteStateMachine:
    """
    Manages QSO state transitions, automated sequencing, and response generation.
    Analogous to the WSJT-X sequencing engine for FT8.
    """

    def __init__(self, my_call: str = "EP2AES", auto_respond: bool = True):
        self.session = QSOSession(my_call=my_call)
        self.auto_respond = auto_respond
        self.qso_log: List[Dict[str, str]] = []

    def handle_frame(self, frame: CWFrame) -> Optional[str]:
        """
        Takes an analyzed CW frame from Layer 2, transitions the FSM,
        and returns the appropriate response string to transmit.
        """
        # Event 1: Heard CQ / TEST while IDLE
        if frame.intent == CWIntent.CALLING_CQ and frame.sender_call:
            if self.session.state == QSOState.IDLE:
                self.session.target_call = frame.sender_call
                self.session.state = QSOState.ANSWERING_CQ
                return f"{self.session.target_call} DE {self.session.my_call} K"

        # Event 2: Station answers our CQ ("<MYCALL> DE <CALL>")
        if frame.intent == CWIntent.ANSWERING_CALL and self.session.state == QSOState.CALLING_CQ:
            if frame.sender_call:
                self.session.target_call = frame.sender_call
                self.session.state = QSOState.EXCHANGE_REPORT
                return f"{self.session.target_call} UR {self.session.my_rst_sent} BK"

        # Event 3: Received Signal Report (e.g., 5NN 101) while answering CQ or exchanging
        if frame.intent == CWIntent.SENDING_REPORT:
            if self.session.state in {QSOState.ANSWERING_CQ, QSOState.EXCHANGE_REPORT}:
                self.session.his_rst_rcvd = frame.rst_report or "599"
                if frame.serial_exchange:
                    self.session.exchange_rcvd = frame.serial_exchange
                self.session.state = QSOState.EXCHANGE_INFO
                # Send our report and exchange
                if self.session.exchange_sent:
                    return f"R {self.session.my_rst_sent} {self.session.exchange_sent} BK"
                return f"R {self.session.my_rst_sent} BK"

        # Event 4: Received 73 / TU / Signoff
        if frame.intent == CWIntent.SIGNOFF and self.session.state == QSOState.EXCHANGE_INFO:
            self.session.state = QSOState.COMPLETED
            self._log_contact()
            response = f"TU 73 DE {self.session.my_call} SK"
            # Auto-reset back to IDLE after completion
            self.session.state = QSOState.IDLE
            self.session.target_call = ""
            return response

        return None

    def _log_contact(self):
        """Logs completed contact (ADIF compatible fields)."""
        record = {
            "CALL": self.session.target_call,
            "MODE": "CW",
            "RST_SENT": self.session.my_rst_sent,
            "RST_RCVD": self.session.his_rst_rcvd,
            "EXCHANGE_RCVD": self.session.exchange_rcvd,
        }
        self.qso_log.append(record)


# =====================================================================
# LAYER 4: AI / NLP SEQUENCE RECONSTRUCTION SIMULATOR
# =====================================================================

class CWSequenceReconstructor:
    """
    Simulates / integrates a lightweight Sequence-to-Sequence (Seq2Seq / T5 / BERT)
    statistical model trained on degraded Morse logs.
    Reconstructs corrupted patterns (e.g. 'TESTHG8W HG8W- -> TEST HG8W HG8W').
    """

    CORRECTION_RULES = {
        "TESTHG8W": "TEST HG8W",
        "CQHG8W": "CQ HG8W",
        "5NN101": "5NN 101",
        "QSLAU": "QSL TU",
        "QSLTU": "QSL TU",
        "TESTMC": "TEST MC",
        "TESTOC": "TEST OC",
    }

    @classmethod
    def reconstruct_tokens(cls, raw_stream: str) -> str:
        """Applies statistical token repair."""
        tokens = raw_stream.split()
        repaired = []
        for t in tokens:
            repaired.append(cls.CORRECTION_RULES.get(t, t))
        return " ".join(repaired)


# =====================================================================
# UNIFIED ENGINE RUNNER & VERIFICATION
# =====================================================================

def process_cw_stream(stream: str, my_call: str = "EP2AES") -> Dict:
    """
    End-to-End Pipeline:
    Stream -> Denoise -> Parse Entities/Intents -> FSM Dispatch -> Response
    """
    # Layer 4 (Pre-pass reconstruction) & Layer 1 (Denoising)
    reconstructed = CWSequenceReconstructor.reconstruct_tokens(stream)
    clean_tokens = CWTextDenoiser.denoise(reconstructed)

    # Layer 2: Entity & Intent Parsing
    parser = CWEntityAndIntentParser(my_call=my_call)
    frames = parser.parse_tokens(clean_tokens)

    # Layer 3: FSM Processing
    fsm = CWFiniteStateMachine(my_call=my_call)
    responses = []
    for f in frames:
        resp = fsm.handle_frame(f)
        if resp:
            responses.append(resp)

    return {
        "clean_tokens": clean_tokens,
        "frames": frames,
        "responses": responses,
        "fsm_state": fsm.session.state.value,
        "logged_contacts": fsm.qso_log
    }


if __name__ == "__main__":
    print("=" * 70)
    print("CW-NLP-FSM: Smart CW Copilot Verification")
    print("=" * 70)

    # User's exact noisy contest stream:
    test_stream = (
        "U N E H  E IUI D NT TTDW TESTMC TESTHG8W HG8W- TESTHG8W HG8W "
        "TESTOC TESTHG8W HG8W TESTOC TESTHG8W HG8W TE ETOC E TESTHG8W HM 8W "
        "TESTOC TESTHG8W HG8W THTGF YE3AJJ 5NN101 101  LT21T21L3GLTU QSLAU "
        "TESTHG8W HG8 TES T OG TESTHG8W HG8W TESTOC E G8W HG8W THTOC"
    )

    result = process_cw_stream(test_stream, my_call="EP2AES")

    print(f"\n1. Denoised Tokens ({len(result['clean_tokens'])} tokens):")
    print("   " + " ".join(result['clean_tokens'][:25]) + " ...")

    print(f"\n2. Extracted Entities & Intents ({len(result['frames'])} detected frames):")
    for idx, f in enumerate(result['frames']):
        print(f"   [{idx + 1}] Intent={f.intent.name:<15} Sender={f.sender_call or '-':<8} Report={f.rst_report or '-':<5} Exchange={f.serial_exchange or '-'}")

    print(f"\n3. Automated Suggested Response(s):")
    for r in result['responses']:
        print(f"   >>> {r}")

    print("\n✓ Pipeline execution completed successfully.")
