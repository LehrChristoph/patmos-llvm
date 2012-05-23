//===-- PatmosInstPrinter.h - Convert Patmos MCInst to assembly syntax ----===//
//
//                     The LLVM Compiler Infrastructure
//
// This file is distributed under the University of Illinois Open Source
// License. See LICENSE.TXT for details.
//
//===----------------------------------------------------------------------===//
//
// This class prints a Patmos MCInst to a .s file.
//
//===----------------------------------------------------------------------===//

#ifndef _PATMOS_INSTPRINTER_H_
#define _PATMOS_INSTPRINTER_H_

#include "llvm/MC/MCInstPrinter.h"

namespace llvm {
  class MCOperand;

  class PatmosInstPrinter : public MCInstPrinter {
  public:
    PatmosInstPrinter(const MCAsmInfo &mai, const MCInstrInfo &mii,
	                    const MCRegisterInfo &mri)
        : MCInstPrinter(mai, mii, mri) {}


    void printInst(const MCInst *MI, raw_ostream &O, StringRef Annot);
    void printOperand(const MCInst *MI, unsigned OpNo,
                      raw_ostream &O, const char *Modifier = 0);
    void printPredicateOperand(const MCInst *MI, unsigned OpNo,
                               raw_ostream &O);
    // Autogenerated by tblgen.
    void printInstruction(const MCInst *MI, raw_ostream &O);
    static const char *getRegisterName(unsigned RegNo);
  };
}

#endif // _PATMOS_INSTPRINTER_H_
