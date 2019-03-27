/****************************************************************************/
/*                           the diy toolsuite                              */
/*                                                                          */
/* Jade Alglave, University College London, UK.                             */
/* Luc Maranget, INRIA Paris-Rocquencourt, France.                          */
/*                                                                          */
/* Copyright 2019-present Institut National de Recherche en Informatique et */
/* en Automatique and the authors. All rights reserved.                     */
/*                                                                          */
/* This software is governed by the CeCILL-B license under French law and   */
/* abiding by the rules of distribution of free software. You can use,      */
/* modify and/ or redistribute the software under the terms of the CeCILL-B */
/* license as circulated by CEA, CNRS and INRIA at the following URL        */
/* "http://www.cecill.info". We also give a copy in LICENSE.txt.            */
/****************************************************************************/

/***********************************/
/* Support for self-modifying code */
/***********************************/

typedef uint32_t ins_t ;

inline static void selfbar(void *p) {
  asm __volatile__
    ("dc cvau,%[p]\n\t" "dsb sy\n\t" "ic ivau,%[p]\n\t" "dsb sy\n\t" "isb"
     ::[p]"r"(p): "memory");
}

static ins_t getret(void) {
  uint32_t *x1;
  uint32_t r;
  asm __volatile__ (
  "adr %[x1],0f\n\t"
  "ldr %w[x2],[%[x1]]\n\t"
  "b 1f\n"
  "0:\n\t"
  "ret\n"
  "1:\n"
:[x1] "=&r" (x1),[x2] "=&r" (r)
:
: "cc","memory"
);
  return r;
}
