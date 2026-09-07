/*
 * M9A: the narrow C shim between Trinket.Fonts and FreeType.
 *
 * Keeps the Ada side free of FreeType struct layouts: Ada deals in
 * opaque face handles, codepoints, and raster bitmaps. One global
 * FT_Library is created lazily and never destroyed (process exit).
 * A face keeps its base memory alive — the caller must hold the
 * font file bytes for the face's lifetime.
 */

#include <ft2build.h>
#include FT_FREETYPE_H
#include <stddef.h>
#include <stdlib.h>

struct aegir_ft_face {
  FT_Face face;
};

static FT_Library g_lib = 0;

/* 0 = ok. */
static int aegir_ft_lib(void)
{
  if (!g_lib)
    return FT_Init_FreeType(&g_lib);
  return 0;
}

/* Open a face from memory at the given pixel size (0 = ok, else
 * NULL). The data pointer must outlive the returned handle. */
void *aegir_ft_open(const unsigned char *data, unsigned long len,
                    unsigned px)
{
  struct aegir_ft_face *f;
  int rc;

  if (!data || len == 0)
    return NULL;
  if (aegir_ft_lib())
    return NULL;

  f = (struct aegir_ft_face *)malloc(sizeof *f);
  if (!f)
    return NULL;

  rc = FT_New_Memory_Face(g_lib, data, len, 0, &f->face);
  if (rc) {
    free(f);
    return NULL;
  }
  rc = FT_Set_Pixel_Sizes(f->face, 0, px);
  if (rc) {
    FT_Done_Face(f->face);
    free(f);
    return NULL;
  }
  return f;
}

void aegir_ft_close(void *v)
{
  struct aegir_ft_face *f = (struct aegir_ft_face *)v;
  if (!f)
    return;
  FT_Done_Face(f->face);
  free(f);
}

/* PostScript name of the face ("" when absent) — used as the
 * family key in the font picker. */
const char *aegir_ft_family(void *v)
{
  const char *n;
  struct aegir_ft_face *f = (struct aegir_ft_face *)v;
  if (!f)
    return "";
  n = FT_Get_Postscript_Name(f->face);
  return n ? n : "";
}

/* Ascender / descender / line height in pixels (line top to line
 * top = ascent + descent). */
int aegir_ft_ascent(void *v)
{
  struct aegir_ft_face *f = (struct aegir_ft_face *)v;
  FT_Size_Metrics m;
  if (!f)
    return 0;
  m = f->face->size->metrics;
  return (int)((m.ascender + 32) >> 6);
}

int aegir_ft_descent(void *v)
{
  struct aegir_ft_face *f = (struct aegir_ft_face *)v;
  FT_Size_Metrics m;
  if (!f)
    return 0;
  m = f->face->size->metrics;
  return (int)((-m.descender + 32) >> 6);
}

/* Horizontal advance of a codepoint in pixels (0 when absent). */
int aegir_ft_advance_x(void *v, unsigned long cp)
{
  struct aegir_ft_face *f = (struct aegir_ft_face *)v;
  FT_UInt idx;
  if (!f)
    return 0;
  idx = FT_Get_Char_Index(f->face, (FT_ULong)cp);
  if (!idx)
    return 0;
  if (FT_Load_Glyph(f->face, idx, FT_LOAD_DEFAULT))
    return 0;
  return (int)((f->face->glyph->advance.x + 32) >> 6);
}

/* Render a codepoint: 0 = ok with the grayscale bitmap in *bits
 * (valid until the next call on this handle), nonzero = no glyph.
 * left/top are the bitmap origin (bearing relative to the pen),
 * w/h the bitmap size, pitch the row stride. */
int aegir_ft_glyph(void *v, unsigned long cp,
                   int *left, int *top, int *w, int *h, int *pitch,
                   const unsigned char **bits)
{
  struct aegir_ft_face *f = (struct aegir_ft_face *)v;
  FT_UInt idx;
  FT_GlyphSlot slot;

  *w = *h = *pitch = *left = *top = 0;
  *bits = NULL;
  if (!f)
    return 1;
  idx = FT_Get_Char_Index(f->face, (FT_ULong)cp);
  if (!idx)
    return 1;
  if (FT_Load_Glyph(f->face, idx, FT_LOAD_DEFAULT))
    return 1;
  if (FT_Render_Glyph(f->face->glyph, FT_RENDER_MODE_NORMAL))
    return 1;
  slot = f->face->glyph;
  if (slot->bitmap.pixel_mode != FT_PIXEL_MODE_GRAY)
    return 1;
  *left = slot->bitmap_left;
  *top = slot->bitmap_top;
  *w = (int)slot->bitmap.width;
  *h = (int)slot->bitmap.rows;
  *pitch = slot->bitmap.pitch;
  *bits = slot->bitmap.buffer;
  return 0;
}

/* EOF */
