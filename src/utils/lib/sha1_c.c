/*
 ---------------------------------------------------------------------------
 Copyright (c) 2002, Dr Brian Gladman, Worcester, UK.   All rights reserved.

 LICENSE TERMS

 The free distribution and use of this software in both source and binary
 form is allowed (with or without changes) provided that:

   1. distributions of this source code include the above copyright
      notice, this list of conditions and the following disclaimer;

   2. distributions in binary form include the above copyright
      notice, this list of conditions and the following disclaimer
      in the documentation and/or other associated materials;

   3. the copyright holder's name is not used to endorse products
      built using this software without specific written permission.

 ALTERNATIVELY, provided that this notice is retained in full, this product
 may be distributed under the terms of the GNU General Public License (GPL),
 in which case the provisions of the GPL apply INSTEAD OF those given above.

 DISCLAIMER

 This software is provided 'as is' with no explicit or implied warranties
 in respect of its properties, including, but not limited to, correctness
 and/or fitness for purpose.
 ---------------------------------------------------------------------------
 Issue Date: 16/01/2004

 This is a byte oriented version of SHA1 that operates on arrays of bytes
 stored in memory. It runs at 22 cycles per byte on a Pentium P4 processor
 */

/*
    This file is part of mldonkey.

    mldonkey is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    mldonkey is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with mldonkey; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA
     */

/*swap order of arguments in sha1_hash and sha1_end to 'fit' mldonkey*/

#include <string.h>     /* for memcpy() etc.        */
#include <stdlib.h>     /* for _lrotl with VC++     */
#include <caml/config.h>
#include "sha1_c.h"

#if defined(HAVE_BYTESWAP_H)
#  include <byteswap.h>
#endif

#if defined(HAVE_SYS_PARAM_H) || ((defined(__unix__) || defined(unix)) && !defined(USG))
#include <sys/param.h>
#endif

#if defined(__FreeBSD__) && __FreeBSD_version >= 470000
# include <sys/endian.h>
# if (__FreeBSD_version >= 500000)
#  define bswap_32(x) (bswap32(x))
# else
#  define bswap_32(x) (be32toh(x))
# endif
#endif

#define BRG_LITTLE_ENDIAN   1234 /* byte 0 is least significant (i386) */
#define BRG_BIG_ENDIAN      4321 /* byte 0 is most significant (mc68k) */

#ifdef ARCH_BIG_ENDIAN
#      define PLATFORM_BYTE_ORDER BRG_BIG_ENDIAN
#else
#      define PLATFORM_BYTE_ORDER BRG_LITTLE_ENDIAN
#endif

#if defined(__cplusplus)
extern "C"
    {
#endif

#ifdef _MSC_VER
#pragma intrinsic(memcpy)
#endif

#if 0 && defined(_MSC_VER)
#define rotl32  _lrotl
#define rotr32  _lrotr
#else
#define rotl32(x,n)   (((x) << n) | ((x) >> (32 - n)))
#define rotr32(x,n)   (((x) >> n) | ((x) << (32 - n)))
#endif

#if !defined(bswap_32)
#define bswap_32(x) ((rotr32((x), 24) & 0x00ff00ff) | (rotr32((x), 8) & 0xff00ff00))
#endif

#if (PLATFORM_BYTE_ORDER == BRG_LITTLE_ENDIAN)
#define SWAP_BYTES
#else
#undef  SWAP_BYTES
#endif

#if defined(SWAP_BYTES)
#define bsw_32(p,n) \
    { int _i = (n); while(_i--) ((sha1_32t*)p)[_i] = bswap_32(((sha1_32t*)p)[_i]); }
#else
#define bsw_32(p,n)
#endif

#define SHA1_MASK   (SHA1_BLOCK_SIZE - 1)

#if 0

#define ch(x,y,z)       (((x) & (y)) ^ (~(x) & (z)))
#define parity(x,y,z)   ((x) ^ (y) ^ (z))
#define maj(x,y,z)      (((x) & (y)) ^ ((x) & (z)) ^ ((y) & (z)))

#else   /* Discovered by Rich Schroeppel and Colin Plumb   */

#define ch(x,y,z)       ((z) ^ ((x) & ((y) ^ (z))))
#define parity(x,y,z)   ((x) ^ (y) ^ (z))
#define maj(x,y,z)      (((x) & (y)) | ((z) & ((x) ^ (y))))

#endif

/* Compile 64 bytes of hash data into SHA1 context. Note    */
/* that this routine assumes that the byte order in the     */
/* ctx->wbuf[] at this point is in such an order that low   */
/* address bytes in the ORIGINAL byte stream in this buffer */
/* will go to the high end of 32-bit words on BOTH big and  */
/* little endian systems                                    */

#ifdef ARRAY
#define q(v,n)  v[n]
#else
#define q(v,n)  v##n
#endif

#define one_cycle(v,a,b,c,d,e,f,k,h)            \
    q(v,e) += rotr32(q(v,a),27) +               \
              f(q(v,b),q(v,c),q(v,d)) + k + h;  \
    q(v,b)  = rotr32(q(v,b), 2)

#define five_cycle(v,f,k,i)                 \
    one_cycle(v, 0,1,2,3,4, f,k,hf(i  ));   \
    one_cycle(v, 4,0,1,2,3, f,k,hf(i+1));   \
    one_cycle(v, 3,4,0,1,2, f,k,hf(i+2));   \
    one_cycle(v, 2,3,4,0,1, f,k,hf(i+3));   \
    one_cycle(v, 1,2,3,4,0, f,k,hf(i+4))

void sha1_compile(sha1_context ctx[1])
{   sha1_32t    *w = ctx->wbuf;

#ifdef ARRAY
    sha1_32t    v[5];
    memcpy(v, ctx->hash, 5 * sizeof(sha1_32t));
#else
    sha1_32t    v0, v1, v2, v3, v4;
    v0 = ctx->hash[0]; v1 = ctx->hash[1];
    v2 = ctx->hash[2]; v3 = ctx->hash[3];
    v4 = ctx->hash[4];
#endif

#define hf(i)   w[i]

    five_cycle(v, ch, 0x5a827999,  0);
    five_cycle(v, ch, 0x5a827999,  5);
    five_cycle(v, ch, 0x5a827999, 10);
    one_cycle(v,0,1,2,3,4, ch, 0x5a827999, hf(15)); \

#undef  hf
#define hf(i) (w[(i) & 15] = rotl32(                    \
                 w[((i) + 13) & 15] ^ w[((i) + 8) & 15] \
               ^ w[((i) +  2) & 15] ^ w[(i) & 15], 1))

    one_cycle(v,4,0,1,2,3, ch, 0x5a827999, hf(16));
    one_cycle(v,3,4,0,1,2, ch, 0x5a827999, hf(17));
    one_cycle(v,2,3,4,0,1, ch, 0x5a827999, hf(18));
    one_cycle(v,1,2,3,4,0, ch, 0x5a827999, hf(19));

    five_cycle(v, parity, 0x6ed9eba1,  20);
    five_cycle(v, parity, 0x6ed9eba1,  25);
    five_cycle(v, parity, 0x6ed9eba1,  30);
    five_cycle(v, parity, 0x6ed9eba1,  35);

    five_cycle(v, maj, 0x8f1bbcdc,  40);
    five_cycle(v, maj, 0x8f1bbcdc,  45);
    five_cycle(v, maj, 0x8f1bbcdc,  50);
    five_cycle(v, maj, 0x8f1bbcdc,  55);

    five_cycle(v, parity, 0xca62c1d6,  60);
    five_cycle(v, parity, 0xca62c1d6,  65);
    five_cycle(v, parity, 0xca62c1d6,  70);
    five_cycle(v, parity, 0xca62c1d6,  75);

#ifdef ARRAY
    ctx->hash[0] += v[0]; ctx->hash[1] += v[1];
    ctx->hash[2] += v[2]; ctx->hash[3] += v[3];
    ctx->hash[4] += v[4];
#else
    ctx->hash[0] += v0; ctx->hash[1] += v1;
    ctx->hash[2] += v2; ctx->hash[3] += v3;
    ctx->hash[4] += v4;
#endif
}

int sha1_begin(SHA1_CTX* ctx)
{
    ctx->count[0] = ctx->count[1] = 0;
    ctx->hash[0] = 0x67452301;
    ctx->hash[1] = 0xefcdab89;
    ctx->hash[2] = 0x98badcfe;
    ctx->hash[3] = 0x10325476;
    ctx->hash[4] = 0xc3d2e1f0;

    return 0;
}

/* SHA1 hash data in an array of bytes into hash buffer and */
/* call the hash_compile function as required.              */

int sha1_hash(SHA1_CTX* ctx, const unsigned char data[], unsigned long len)
{   sha1_32t pos = (sha1_32t)(ctx->count[0] & SHA1_MASK),
            space = SHA1_BLOCK_SIZE - pos;
    const unsigned char *sp = data;

    if((ctx->count[0] += len) < len)
        ++(ctx->count[1]);

    while(len >= space)     /* tranfer whole blocks if possible  */
    {
        memcpy(((unsigned char*)ctx->wbuf) + pos, sp, space);
        sp += space; len -= space; space = SHA1_BLOCK_SIZE; pos = 0;
        bsw_32(ctx->wbuf, SHA1_BLOCK_SIZE >> 2);
        sha1_compile(ctx);
    }

    memcpy(((unsigned char*)ctx->wbuf) + pos, sp, len);
    return 0;
}

/* SHA1 final padding and digest calculation  */

int sha1_end(SHA1_CTX* ctx, unsigned char hval[])
{   sha1_32t    i = (sha1_32t)(ctx->count[0] & SHA1_MASK);

    /* put bytes in the buffer in an order in which references to   */
    /* 32-bit words will put bytes with lower addresses into the    */
    /* top of 32 bit words on BOTH big and little endian machines   */
    bsw_32(ctx->wbuf, (i + 3) >> 2);

    /* we now need to mask valid bytes and add the padding which is */
    /* a single 1 bit and as many zero bits as necessary. Note that */
    /* we can always add the first padding byte here because the    */
    /* buffer always has at least one empty slot                    */
    ctx->wbuf[i >> 2] &= 0xffffff80 << 8 * (~i & 3);
    ctx->wbuf[i >> 2] |= 0x00000080 << 8 * (~i & 3);

    /* we need 9 or more empty positions, one for the padding byte  */
    /* (above) and eight for the length count. If there is not      */
    /* enough space, pad and empty the buffer                       */
    if(i > SHA1_BLOCK_SIZE - 9)
    {
        if(i < 60) ctx->wbuf[15] = 0;
        sha1_compile(ctx);
        i = 0;
    }
    else    /* compute a word index for the empty buffer positions  */
        i = (i >> 2) + 1;

    while(i < 14) /* and zero pad all but last two positions        */
        ctx->wbuf[i++] = 0;

    /* the following 32-bit length fields are assembled in the      */
    /* wrong byte order on little endian machines but this is       */
    /* corrected later since they are only ever used as 32-bit      */
    /* word values.                                                 */
    ctx->wbuf[14] = (ctx->count[1] << 3) | (ctx->count[0] >> 29);
    ctx->wbuf[15] = ctx->count[0] << 3;
    sha1_compile(ctx);

    /* extract the hash value as bytes in case the hash buffer is   */
    /* misaligned for 32-bit words                                  */
    for(i = 0; i < SHA1_DIGEST_SIZE; ++i)
        hval[i] = (unsigned char)(ctx->hash[i >> 2] >> (8 * (~i & 3)));

    return 0;
}

void sha1(unsigned char hval[], const unsigned char data[], unsigned long len)
{   sha1_context    cx[1];

    sha1_begin(cx); sha1_hash(cx, data, len); sha1_end( cx, hval);
    }

#if defined(__cplusplus)
}
#endif
