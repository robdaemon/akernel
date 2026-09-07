/*
 * M9A: minimal FreeType module table for Aegir.
 *
 * Compiled modules: TrueType driver, SFNT (TrueType/OpenType
 * container), CFF driver (OpenType/CFF) with its psaux/psnames/
 * pshinter auxiliaries, and the smooth + mono rasterizers. No
 * autohinter, Type1/CID/PFR/Type42, BDF/PCF/WINFNT, SVG or SDF.
 *
 * Referenced from userspace/freetype/freetype.gpr via
 * -DFT_CONFIG_MODULES_H=<ftmodule_aegir.h>.
 */

FT_USE_MODULE( FT_Driver_ClassRec, tt_driver_class )
FT_USE_MODULE( FT_Driver_ClassRec, cff_driver_class )
FT_USE_MODULE( FT_Module_Class, psaux_module_class )
FT_USE_MODULE( FT_Module_Class, psnames_module_class )
FT_USE_MODULE( FT_Module_Class, pshinter_module_class )
FT_USE_MODULE( FT_Module_Class, sfnt_module_class )
FT_USE_MODULE( FT_Renderer_Class, ft_smooth_renderer_class )
FT_USE_MODULE( FT_Renderer_Class, ft_raster1_renderer_class )

/* EOF */
