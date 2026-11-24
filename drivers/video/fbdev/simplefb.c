// SPDX-License-Identifier: GPL-2.0-only
/*
 * Simplest possible simple frame-buffer driver, as a platform device
 *
 * Copyright (c) 2013, Stephen Warren
 *
 * Based on q40fb.c, which was:
 * Copyright (C) 2001 Richard Zidlicky <rz@linux-m68k.org>
 *
 * Also based on offb.c, which was:
 * Copyright (C) 1997 Geert Uytterhoeven
 * Copyright (C) 1996 Paul Mackerras
 */

#include <linux/errno.h>
#include <linux/fb.h>
#include <linux/io.h>
#include <linux/module.h>
#include <linux/platform_data/simplefb.h>
#include <linux/platform_device.h>
#include <linux/clk.h>
#include <linux/of.h>
#include <linux/of_clk.h>
#include <linux/of_platform.h>
#include <linux/parser.h>
#include <linux/regulator/consumer.h>
#include <linux/debugfs.h>
#include <linux/of_address.h>
#include <linux/seq_file.h>
#include <linux/string.h>

/* LK framebuffer reservation and DAL address from the ZPD1203 PL/LK log. */
#define ZPD_LK_L3_PHYS		0x7dcaa000
/* mediatek_v2/mtk_disp_ovl.c: DISP_REG_OVL_SRC_CON, BIT(layer). */
#define ZPD_OVL_SRC_CON		0x02c

struct zpd_disp_snap {
	u32 cg0, cg1;
	bool has_ovl, has_rdma, has_dsi, has_pwm;
	bool has_apmixed, has_mipitx, has_larb0, has_l3_pixel;
	u32 apmixed_con5, mipitx_lane, mipitx_pll_pwr;
	u32 mipitx_pll_con0, mipitx_pll_con1;
	u32 larb0_sta, larb0_ovl_nonsec, larb0_ovl_ostd;
	u32 ovl_sta, ovl_intsta, ovl_en, ovl_roi, ovl_src_con;
	u32 ovl_src_after;
	u32 ovl_l0_con, ovl_l0_sz, ovl_l0_pitch, ovl_l0_addr;
	u32 ovl_l3_con, ovl_l3_addr, ovl_l3_pixel;
	u32 rdma_intsta, rdma_gcon, rdma_sz0, rdma_sz1;
	u32 dsi_start, dsi_intsta, dsi_con, dsi_mode;
	u32 pwm_en, pwm_commit, pwm_con0, pwm_con1, pwm_1c;
};

static void zpd_capture_regs(struct zpd_disp_snap *s,
			     const struct fb_info *info,
			     void __iomem *l3_pixel, bool clear_l3)
{
	void __iomem *base;

	memset(s, 0, sizeof(*s));
	base = ioremap(0x14000000, 0x1000);
	if (!base)
		return;
	s->cg0 = readl(base + 0x100);
	s->cg1 = readl(base + 0x110);
	iounmap(base);

	if ((s->cg0 & BIT(7)) == 0) {
		base = ioremap(0x1400b000, 0x1000);
		if (base) {
			s->has_ovl = true;
			s->ovl_sta = readl(base + 0x000);
			s->ovl_intsta = readl(base + 0x008);
			s->ovl_en = readl(base + 0x00c);
			s->ovl_roi = readl(base + 0x020);
			s->ovl_src_con = readl(base + ZPD_OVL_SRC_CON);
			s->ovl_src_after = s->ovl_src_con;
			s->ovl_l0_con = readl(base + 0x030);
			s->ovl_l0_sz = readl(base + 0x038);
			s->ovl_l0_pitch = readl(base + 0x044);
			s->ovl_l0_addr = readl(base + 0x0f40);
			s->ovl_l3_con = readl(base + 0x090);
			s->ovl_l3_addr = readl(base + 0x0fa0);
			if (l3_pixel && s->ovl_l3_addr == ZPD_LK_L3_PHYS) {
				s->has_l3_pixel = true;
				s->ovl_l3_pixel = readl(l3_pixel);
			}
			/* Keep L0 and any unrelated SRC_CON bits intact. */
			if (clear_l3 && s->has_l3_pixel && (s->ovl_en & BIT(0)) &&
			    s->ovl_l0_addr == info->fix.smem_start &&
			    (s->ovl_src_con & GENMASK(3, 0)) == (BIT(0) | BIT(3))) {
				writel(s->ovl_src_con & ~BIT(3),
				       base + ZPD_OVL_SRC_CON);
				s->ovl_src_after = readl(base + ZPD_OVL_SRC_CON);
			}
			iounmap(base);
		}
	}

	if ((s->cg0 & BIT(10)) == 0) {
		base = ioremap(0x1400d000, 0x1000);
		if (base) {
			s->has_rdma = true;
			s->rdma_intsta = readl(base + 0x004);
			s->rdma_gcon = readl(base + 0x010);
			s->rdma_sz0 = readl(base + 0x014);
			s->rdma_sz1 = readl(base + 0x018);
			iounmap(base);
		}
	}

	if ((s->cg0 & BIT(17)) == 0) {
		base = ioremap(0x14014000, 0x1000);
		if (base) {
			s->has_dsi = true;
			s->dsi_start = readl(base + 0x000);
			s->dsi_intsta = readl(base + 0x00c);
			s->dsi_con = readl(base + 0x010);
			s->dsi_mode = readl(base + 0x014);
			iounmap(base);
		}
	}

	/* mt6768.dts apmixed, clk-mt6768.c apmixed_mipid026m (active high). */
	base = ioremap(0x1000c000, 0x1000);
	if (base) {
		s->has_apmixed = true;
		s->apmixed_con5 = readl(base + 0x014);
		iounmap(base);
	}

	/* mt6768.dts mipi_tx_config0 and mediatek_v2/mtk_mipi_tx.h. */
	if (!(s->cg0 & (BIT(17) | BIT(30))) &&
	    s->has_apmixed && (s->apmixed_con5 & BIT(16))) {
		base = ioremap(0x11c80000, 0x1000);
		if (base) {
			s->has_mipitx = true;
			s->mipitx_lane = readl(base + 0x00c);
			s->mipitx_pll_pwr = readl(base + 0x028);
			s->mipitx_pll_con0 = readl(base + 0x02c);
			s->mipitx_pll_con1 = readl(base + 0x030);
			iounmap(base);
		}
	}

	/* mt6768.dts smi_larb0, mtk-smi.c, M4U_PORT_DISP_OVL0 = port 0. */
	if (!(s->cg0 & (BIT(19) | BIT(20)))) {
		base = ioremap(0x14003000, 0x1000);
		if (base) {
			s->has_larb0 = true;
			s->larb0_sta = readl(base + 0x000);
			s->larb0_ovl_ostd = readl(base + 0x200);
			s->larb0_ovl_nonsec = readl(base + 0x380);
			iounmap(base);
		}
	}

	base = ioremap(0x1100e000, 0x1000);
	if (base) {
		s->has_pwm = true;
		s->pwm_en = readl(base + 0x000);
		s->pwm_commit = readl(base + 0x00c);
		s->pwm_con0 = readl(base + 0x010);
		s->pwm_con1 = readl(base + 0x014);
		s->pwm_1c = readl(base + 0x01c);
		iounmap(base);
	}
}

static void zpd_print_snap(struct seq_file *m, const char *tag,
			   const struct zpd_disp_snap *s)
{
	seq_printf(m, "[%s] MMSYS CG_CON0=0x%08x CG_CON1=0x%08x (ovl=%d rdma=%d dsi=%d smi_com=%d smi_larb0=%d dig_dsi=%d)\n",
		   tag, s->cg0, s->cg1,
		   !(s->cg0 & BIT(7)), !(s->cg0 & BIT(10)), !(s->cg0 & BIT(17)),
		   !(s->cg0 & BIT(19)), !(s->cg0 & BIT(20)), !(s->cg0 & BIT(30)));
	if (s->has_ovl) {
		seq_printf(m, "  OVL0:  STA=0x%08x INTSTA=0x%08x EN=0x%08x ROI=0x%08x SRC_CON=0x%08x\n",
			   s->ovl_sta, s->ovl_intsta, s->ovl_en, s->ovl_roi, s->ovl_src_con);
		seq_printf(m, "  OVL0 L0: CON=0x%08x SZ=0x%08x PITCH=0x%08x ADDR=0x%08x | L3: CON=0x%08x ADDR=0x%08x\n",
			   s->ovl_l0_con, s->ovl_l0_sz, s->ovl_l0_pitch, s->ovl_l0_addr,
			   s->ovl_l3_con, s->ovl_l3_addr);
		if (s->has_l3_pixel)
			seq_printf(m, "  OVL0 L3: px(0,0)=0x%08x\n", s->ovl_l3_pixel);
		else
			seq_puts(m, "  OVL0 L3: pixel unavailable (LK buffer not verified/mapped)\n");
		if (s->ovl_src_after != s->ovl_src_con)
			seq_printf(m, "  OVL0: SRC_CON after clearing L3=0x%08x\n",
				   s->ovl_src_after);
	} else {
		seq_puts(m, "  OVL0:  GATED (CG_CON0 bit7=1)\n");
	}
	if (s->has_rdma) {
		seq_printf(m, "  RDMA0: INT_STA=0x%08x GLOBAL_CON=0x%08x SIZE0=0x%08x SIZE1=0x%08x\n",
			   s->rdma_intsta, s->rdma_gcon, s->rdma_sz0, s->rdma_sz1);
	} else {
		seq_puts(m, "  RDMA0: GATED (CG_CON0 bit10=1)\n");
	}
	if (s->has_dsi) {
		seq_printf(m, "  DSI0:  START=0x%08x INTSTA=0x%08x CON=0x%08x MODE=0x%08x\n",
			   s->dsi_start, s->dsi_intsta, s->dsi_con, s->dsi_mode);
	} else {
		seq_puts(m, "  DSI0:  GATED (CG_CON0 bit17=1)\n");
	}
	if (s->has_apmixed)
		seq_printf(m, "  APMIXED: AP_PLL_CON5=0x%08x MIPID0_26M_EN=%d\n",
			   s->apmixed_con5, !!(s->apmixed_con5 & BIT(16)));
	if (s->has_mipitx)
		seq_printf(m, "  MIPI_TX0: LANE_CON=0x%08x PLL_PWR=0x%08x PLL_CON0=0x%08x PLL_CON1=0x%08x\n",
			   s->mipitx_lane, s->mipitx_pll_pwr,
			   s->mipitx_pll_con0, s->mipitx_pll_con1);
	else
		seq_puts(m, "  MIPI_TX0: unavailable (clock gated or mapping failed)\n");
	if (s->has_larb0)
		seq_printf(m, "  SMI_LARB0: STAT=0x%08x OVL0_OSTDL=0x%08x OVL0_NONSEC_CON=0x%08x (MMU_EN=%d)\n",
			   s->larb0_sta, s->larb0_ovl_ostd,
			   s->larb0_ovl_nonsec, !!(s->larb0_ovl_nonsec & BIT(0)));
	else
		seq_puts(m, "  SMI_LARB0: unavailable (clock gated or mapping failed)\n");
	if (s->has_pwm) {
		seq_printf(m, "  PWM0:  EN=0x%08x COMMIT=0x%08x CON0=0x%08x CON1=0x%08x REG1C=0x%08x\n",
			   s->pwm_en, s->pwm_commit, s->pwm_con0, s->pwm_con1, s->pwm_1c);
	}
}

static const struct fb_fix_screeninfo simplefb_fix = {
	.id		= "simple",
	.type		= FB_TYPE_PACKED_PIXELS,
	.visual		= FB_VISUAL_TRUECOLOR,
	.accel		= FB_ACCEL_NONE,
};

static const struct fb_var_screeninfo simplefb_var = {
	.height		= -1,
	.width		= -1,
	.activate	= FB_ACTIVATE_NOW,
	.vmode		= FB_VMODE_NONINTERLACED,
};

#define PSEUDO_PALETTE_SIZE 16

static int simplefb_setcolreg(u_int regno, u_int red, u_int green, u_int blue,
			      u_int transp, struct fb_info *info)
{
	u32 *pal = info->pseudo_palette;
	u32 cr = red >> (16 - info->var.red.length);
	u32 cg = green >> (16 - info->var.green.length);
	u32 cb = blue >> (16 - info->var.blue.length);
	u32 value;

	if (regno >= PSEUDO_PALETTE_SIZE)
		return -EINVAL;

	value = (cr << info->var.red.offset) |
		(cg << info->var.green.offset) |
		(cb << info->var.blue.offset);
	if (info->var.transp.length > 0) {
		u32 mask = (1 << info->var.transp.length) - 1;
		mask <<= info->var.transp.offset;
		value |= mask;
	}
	pal[regno] = value;

	return 0;
}

struct simplefb_par;
static void simplefb_clocks_destroy(struct simplefb_par *par);
static void simplefb_regulators_destroy(struct simplefb_par *par);

static void simplefb_destroy(struct fb_info *info)
{
	simplefb_regulators_destroy(info->par);
	simplefb_clocks_destroy(info->par);
	if (info->screen_base)
		iounmap(info->screen_base);
}

static const struct fb_ops simplefb_ops = {
	.owner		= THIS_MODULE,
	.fb_destroy	= simplefb_destroy,
	.fb_setcolreg	= simplefb_setcolreg,
	.fb_fillrect	= cfb_fillrect,
	.fb_copyarea	= cfb_copyarea,
	.fb_imageblit	= cfb_imageblit,
};

static struct simplefb_format simplefb_formats[] = SIMPLEFB_FORMATS;

struct simplefb_params {
	u32 width;
	u32 height;
	u32 stride;
	struct simplefb_format *format;
};

static int simplefb_parse_dt(struct platform_device *pdev,
			   struct simplefb_params *params)
{
	struct device_node *np = pdev->dev.of_node;
	int ret;
	const char *format;
	int i;

	ret = of_property_read_u32(np, "width", &params->width);
	if (ret) {
		dev_err(&pdev->dev, "Can't parse width property\n");
		return ret;
	}

	ret = of_property_read_u32(np, "height", &params->height);
	if (ret) {
		dev_err(&pdev->dev, "Can't parse height property\n");
		return ret;
	}

	ret = of_property_read_u32(np, "stride", &params->stride);
	if (ret) {
		dev_err(&pdev->dev, "Can't parse stride property\n");
		return ret;
	}

	ret = of_property_read_string(np, "format", &format);
	if (ret) {
		dev_err(&pdev->dev, "Can't parse format property\n");
		return ret;
	}
	params->format = NULL;
	for (i = 0; i < ARRAY_SIZE(simplefb_formats); i++) {
		if (strcmp(format, simplefb_formats[i].name))
			continue;
		params->format = &simplefb_formats[i];
		break;
	}
	if (!params->format) {
		dev_err(&pdev->dev, "Invalid format value\n");
		return -EINVAL;
	}

	return 0;
}

static int simplefb_parse_pd(struct platform_device *pdev,
			     struct simplefb_params *params)
{
	struct simplefb_platform_data *pd = dev_get_platdata(&pdev->dev);
	int i;

	params->width = pd->width;
	params->height = pd->height;
	params->stride = pd->stride;

	params->format = NULL;
	for (i = 0; i < ARRAY_SIZE(simplefb_formats); i++) {
		if (strcmp(pd->format, simplefb_formats[i].name))
			continue;

		params->format = &simplefb_formats[i];
		break;
	}

	if (!params->format) {
		dev_err(&pdev->dev, "Invalid format value\n");
		return -EINVAL;
	}

	return 0;
}

struct simplefb_par {
	u32 palette[PSEUDO_PALETTE_SIZE];
	struct dentry *zpd_debugfs;
	void __iomem *zpd_l3_pixel;
	struct zpd_disp_snap zpd_boot_snap;
#if defined CONFIG_OF && defined CONFIG_COMMON_CLK
	bool clks_enabled;
	unsigned int clk_count;
	struct clk **clks;
#endif
#if defined CONFIG_OF && defined CONFIG_REGULATOR
	bool regulators_enabled;
	u32 regulator_count;
	struct regulator **regulators;
#endif
};

static int zpd_disp_regs_show(struct seq_file *m, void *v)
{
	const struct fb_info *info = m->private;
	const struct simplefb_par *par = info->par;
	struct zpd_disp_snap live;
	u32 px_0_0 = 0, px_mid = 0;
	u32 stride = info->fix.line_length;
	u32 size = info->fix.smem_len;
	u64 mid_off = 1000ULL * stride + 600U * 4U;

	zpd_capture_regs(&live, info, par->zpd_l3_pixel, false);
	zpd_print_snap(m, "BOOT", &par->zpd_boot_snap);
	zpd_print_snap(m, "LIVE", &live);
	if (size >= sizeof(u32))
		px_0_0 = readl(info->screen_base);
	if (stride && mid_off + sizeof(u32) <= size)
		px_mid = readl(info->screen_base + mid_off);
	seq_printf(m, "[FB0 screen_base] stride=%u size=%u px(0,0)=0x%08x px(600,1000)=0x%08x\n",
		   stride, size, px_0_0, px_mid);
	return 0;
}
DEFINE_SHOW_ATTRIBUTE(zpd_disp_regs);

static void __iomem *zpd_map_l3_pixel(struct device *dev)
{
	struct device_node *reserved, *node;
	struct resource res;
	void __iomem *pixel = NULL;

	reserved = of_find_node_by_path("/reserved-memory");
	if (!reserved)
		return NULL;

	/* LK injects the no-map framebuffer node at boot with a variable index. */
	for_each_available_child_of_node(reserved, node) {
		if (of_address_to_resource(node, 0, &res) ||
		    !of_property_read_bool(node, "no-map") ||
		    res.start > ZPD_LK_L3_PHYS ||
		    res.end < ZPD_LK_L3_PHYS + sizeof(u32) - 1)
			continue;

		pixel = devm_ioremap_wc(dev, ZPD_LK_L3_PHYS, sizeof(u32));
		of_node_put(node);
		break;
	}
	of_node_put(reserved);
	return pixel;
}

#if defined CONFIG_OF && defined CONFIG_COMMON_CLK
/*
 * Clock handling code.
 *
 * Here we handle the clocks property of our "simple-framebuffer" dt node.
 * This is necessary so that we can make sure that any clocks needed by
 * the display engine that the bootloader set up for us (and for which it
 * provided a simplefb dt node), stay up, for the life of the simplefb
 * driver.
 *
 * When the driver unloads, we cleanly disable, and then release the clocks.
 *
 * We only complain about errors here, no action is taken as the most likely
 * error can only happen due to a mismatch between the bootloader which set
 * up simplefb, and the clock definitions in the device tree. Chances are
 * that there are no adverse effects, and if there are, a clean teardown of
 * the fb probe will not help us much either. So just complain and carry on,
 * and hope that the user actually gets a working fb at the end of things.
 */
static int simplefb_clocks_get(struct simplefb_par *par,
			       struct platform_device *pdev)
{
	struct device_node *np = pdev->dev.of_node;
	struct clk *clock;
	int i;

	if (dev_get_platdata(&pdev->dev) || !np)
		return 0;

	par->clk_count = of_clk_get_parent_count(np);
	if (!par->clk_count)
		return 0;

	par->clks = kcalloc(par->clk_count, sizeof(struct clk *), GFP_KERNEL);
	if (!par->clks)
		return -ENOMEM;

	for (i = 0; i < par->clk_count; i++) {
		clock = of_clk_get(np, i);
		if (IS_ERR(clock)) {
			if (PTR_ERR(clock) == -EPROBE_DEFER) {
				while (--i >= 0) {
					if (par->clks[i])
						clk_put(par->clks[i]);
				}
				kfree(par->clks);
				return -EPROBE_DEFER;
			}
			dev_err(&pdev->dev, "%s: clock %d not found: %ld\n",
				__func__, i, PTR_ERR(clock));
			continue;
		}
		par->clks[i] = clock;
	}

	return 0;
}

static void simplefb_clocks_enable(struct simplefb_par *par,
				   struct platform_device *pdev)
{
	int i, ret;

	for (i = 0; i < par->clk_count; i++) {
		if (par->clks[i]) {
			ret = clk_prepare_enable(par->clks[i]);
			if (ret) {
				dev_err(&pdev->dev,
					"%s: failed to enable clock %d: %d\n",
					__func__, i, ret);
				clk_put(par->clks[i]);
				par->clks[i] = NULL;
			}
		}
	}
	par->clks_enabled = true;
}

static void simplefb_clocks_destroy(struct simplefb_par *par)
{
	int i;

	if (!par->clks)
		return;

	for (i = 0; i < par->clk_count; i++) {
		if (par->clks[i]) {
			if (par->clks_enabled)
				clk_disable_unprepare(par->clks[i]);
			clk_put(par->clks[i]);
		}
	}

	kfree(par->clks);
}
#else
static int simplefb_clocks_get(struct simplefb_par *par,
	struct platform_device *pdev) { return 0; }
static void simplefb_clocks_enable(struct simplefb_par *par,
	struct platform_device *pdev) { }
static void simplefb_clocks_destroy(struct simplefb_par *par) { }
#endif

#if defined CONFIG_OF && defined CONFIG_REGULATOR

#define SUPPLY_SUFFIX "-supply"

/*
 * Regulator handling code.
 *
 * Here we handle the num-supplies and vin*-supply properties of our
 * "simple-framebuffer" dt node. This is necessary so that we can make sure
 * that any regulators needed by the display hardware that the bootloader
 * set up for us (and for which it provided a simplefb dt node), stay up,
 * for the life of the simplefb driver.
 *
 * When the driver unloads, we cleanly disable, and then release the
 * regulators.
 *
 * We only complain about errors here, no action is taken as the most likely
 * error can only happen due to a mismatch between the bootloader which set
 * up simplefb, and the regulator definitions in the device tree. Chances are
 * that there are no adverse effects, and if there are, a clean teardown of
 * the fb probe will not help us much either. So just complain and carry on,
 * and hope that the user actually gets a working fb at the end of things.
 */
static int simplefb_regulators_get(struct simplefb_par *par,
				   struct platform_device *pdev)
{
	struct device_node *np = pdev->dev.of_node;
	struct property *prop;
	struct regulator *regulator;
	const char *p;
	int count = 0, i = 0;

	if (dev_get_platdata(&pdev->dev) || !np)
		return 0;

	/* Count the number of regulator supplies */
	for_each_property_of_node(np, prop) {
		p = strstr(prop->name, SUPPLY_SUFFIX);
		if (p && p != prop->name)
			count++;
	}

	if (!count)
		return 0;

	par->regulators = devm_kcalloc(&pdev->dev, count,
				       sizeof(struct regulator *), GFP_KERNEL);
	if (!par->regulators)
		return -ENOMEM;

	/* Get all the regulators */
	for_each_property_of_node(np, prop) {
		char name[32]; /* 32 is max size of property name */

		p = strstr(prop->name, SUPPLY_SUFFIX);
		if (!p || p == prop->name)
			continue;

		strlcpy(name, prop->name,
			strlen(prop->name) - strlen(SUPPLY_SUFFIX) + 1);
		regulator = devm_regulator_get_optional(&pdev->dev, name);
		if (IS_ERR(regulator)) {
			if (PTR_ERR(regulator) == -EPROBE_DEFER)
				return -EPROBE_DEFER;
			dev_err(&pdev->dev, "regulator %s not found: %ld\n",
				name, PTR_ERR(regulator));
			continue;
		}
		par->regulators[i++] = regulator;
	}
	par->regulator_count = i;

	return 0;
}

static void simplefb_regulators_enable(struct simplefb_par *par,
				       struct platform_device *pdev)
{
	int i, ret;

	/* Enable all the regulators */
	for (i = 0; i < par->regulator_count; i++) {
		ret = regulator_enable(par->regulators[i]);
		if (ret) {
			dev_err(&pdev->dev,
				"failed to enable regulator %d: %d\n",
				i, ret);
			devm_regulator_put(par->regulators[i]);
			par->regulators[i] = NULL;
		}
	}
	par->regulators_enabled = true;
}

static void simplefb_regulators_destroy(struct simplefb_par *par)
{
	int i;

	if (!par->regulators || !par->regulators_enabled)
		return;

	for (i = 0; i < par->regulator_count; i++)
		if (par->regulators[i])
			regulator_disable(par->regulators[i]);
}
#else
static int simplefb_regulators_get(struct simplefb_par *par,
	struct platform_device *pdev) { return 0; }
static void simplefb_regulators_enable(struct simplefb_par *par,
	struct platform_device *pdev) { }
static void simplefb_regulators_destroy(struct simplefb_par *par) { }
#endif

static int simplefb_probe(struct platform_device *pdev)
{
	int ret;
	struct simplefb_params params;
	struct fb_info *info;
	struct simplefb_par *par;
	struct resource *mem;

	if (fb_get_options("simplefb", NULL))
		return -ENODEV;

	ret = -ENODEV;
	if (dev_get_platdata(&pdev->dev))
		ret = simplefb_parse_pd(pdev, &params);
	else if (pdev->dev.of_node)
		ret = simplefb_parse_dt(pdev, &params);

	if (ret)
		return ret;

	mem = platform_get_resource(pdev, IORESOURCE_MEM, 0);
	if (!mem) {
		dev_err(&pdev->dev, "No memory resource\n");
		return -EINVAL;
	}

	info = framebuffer_alloc(sizeof(struct simplefb_par), &pdev->dev);
	if (!info)
		return -ENOMEM;
	platform_set_drvdata(pdev, info);

	par = info->par;

	info->fix = simplefb_fix;
	info->fix.smem_start = mem->start;
	info->fix.smem_len = resource_size(mem);
	info->fix.line_length = params.stride;

	info->var = simplefb_var;
	info->var.xres = params.width;
	info->var.yres = params.height;
	info->var.xres_virtual = params.width;
	info->var.yres_virtual = params.height;
	info->var.bits_per_pixel = params.format->bits_per_pixel;
	info->var.red = params.format->red;
	info->var.green = params.format->green;
	info->var.blue = params.format->blue;
	info->var.transp = params.format->transp;

	info->apertures = alloc_apertures(1);
	if (!info->apertures) {
		ret = -ENOMEM;
		goto error_fb_release;
	}
	info->apertures->ranges[0].base = info->fix.smem_start;
	info->apertures->ranges[0].size = info->fix.smem_len;

	info->fbops = &simplefb_ops;
	info->flags = FBINFO_DEFAULT | FBINFO_MISC_FIRMWARE;
	info->screen_base = ioremap_wc(info->fix.smem_start,
				       info->fix.smem_len);
	if (!info->screen_base) {
		ret = -ENOMEM;
		goto error_fb_release;
	}
	info->pseudo_palette = par->palette;

	ret = simplefb_clocks_get(par, pdev);
	if (ret < 0)
		goto error_unmap;

	ret = simplefb_regulators_get(par, pdev);
	if (ret < 0)
		goto error_clocks;

	simplefb_clocks_enable(par, pdev);
	simplefb_regulators_enable(par, pdev);

	dev_info(&pdev->dev, "framebuffer at 0x%lx, 0x%x bytes, mapped to 0x%p\n",
			     info->fix.smem_start, info->fix.smem_len,
			     info->screen_base);
	dev_info(&pdev->dev, "format=%s, mode=%dx%dx%d, linelength=%d\n",
			     params.format->name,
			     info->var.xres, info->var.yres,
			     info->var.bits_per_pixel, info->fix.line_length);

	ret = register_framebuffer(info);
	if (ret < 0) {
		dev_err(&pdev->dev, "Unable to register simplefb: %d\n", ret);
		goto error_regulators;
	}

	dev_info(&pdev->dev, "fb%d: simplefb registered!\n", info->node);

	if (of_property_read_bool(pdev->dev.of_node, "mediatek,zpd1203-lk-display")) {
		par->zpd_l3_pixel = zpd_map_l3_pixel(&pdev->dev);
		zpd_capture_regs(&par->zpd_boot_snap, info, par->zpd_l3_pixel, true);
		dev_info(&pdev->dev, "ZPD OVL0 SRC_CON: %#x -> %#x\n",
			 par->zpd_boot_snap.ovl_src_con, par->zpd_boot_snap.ovl_src_after);
		par->zpd_debugfs = debugfs_create_file("zpd_disp_regs", 0444, NULL,
						      info, &zpd_disp_regs_fops);
	}

	return 0;

error_regulators:
	simplefb_regulators_destroy(par);
error_clocks:
	simplefb_clocks_destroy(par);
error_unmap:
	iounmap(info->screen_base);
error_fb_release:
	framebuffer_release(info);
	return ret;
}

static int simplefb_remove(struct platform_device *pdev)
{
	struct fb_info *info = platform_get_drvdata(pdev);
	struct simplefb_par *par = info->par;

	debugfs_remove(par->zpd_debugfs);
	unregister_framebuffer(info);
	framebuffer_release(info);

	return 0;
}

static const struct of_device_id simplefb_of_match[] = {
	{ .compatible = "simple-framebuffer", },
	{ },
};
MODULE_DEVICE_TABLE(of, simplefb_of_match);

static struct platform_driver simplefb_driver = {
	.driver = {
		.name = "simple-framebuffer",
		.of_match_table = simplefb_of_match,
	},
	.probe = simplefb_probe,
	.remove = simplefb_remove,
};

static int __init simplefb_init(void)
{
	int ret;
	struct device_node *np;

	ret = platform_driver_register(&simplefb_driver);
	if (ret)
		return ret;

	if (IS_ENABLED(CONFIG_OF_ADDRESS) && of_chosen) {
		for_each_child_of_node(of_chosen, np) {
			if (of_device_is_compatible(np, "simple-framebuffer"))
				of_platform_device_create(np, NULL, NULL);
		}
	}

	return 0;
}

fs_initcall(simplefb_init);

MODULE_AUTHOR("Stephen Warren <swarren@wwwdotorg.org>");
MODULE_DESCRIPTION("Simple framebuffer driver");
MODULE_LICENSE("GPL v2");
