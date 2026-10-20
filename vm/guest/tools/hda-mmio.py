#!/usr/bin/env python3
# hda-mmio.py: read and drive an HDA controller through BAR0 from userspace.
# Stdlib only. Run as root with "python3 -I". Use only when no driver is bound.
"""Talk to an HD-audio controller through /sys/bus/pci/devices/<BDF>/resource0.

Commands:
  dump                      decode all controller registers (read-only)
  reset                     controller reset (GCTL.CRST 0 -> 1), show STATESTS
  verb ADDR NID VERB PARAM  send one verb with the Immediate Command interface
  probe                     reset, then read vendor/revision/nodes per codec
  read OFF [WIDTH]          read one register (--bar selects the BAR)
  write OFF VAL [WIDTH]     write one register (--bar selects the BAR)
  corb                      explain why CORB/RIRB is not tested here

The immediate command interface (IC/IR/ICS) is pure MMIO: no DMA.
If it works while the kernel CORB/RIRB path fails, the DMA path is broken.
"""

import argparse
import mmap
import os
import struct
import sys
import time

SYSFS_PCI = "/sys/bus/pci/devices"

# Register offsets and widths (bytes), HDA spec 1.0a section 3.3.
REGS = [
	("GCAP", 0x00, 2), ("VMIN", 0x02, 1), ("VMAJ", 0x03, 1),
	("OUTPAY", 0x04, 2), ("INPAY", 0x06, 2), ("GCTL", 0x08, 4),
	("WAKEEN", 0x0c, 2), ("STATESTS", 0x0e, 2), ("GSTS", 0x10, 2),
	("INTCTL", 0x20, 4), ("INTSTS", 0x24, 4), ("WALCLK", 0x30, 4),
	("CORBLBASE", 0x40, 4), ("CORBUBASE", 0x44, 4), ("CORBWP", 0x48, 2),
	("CORBRP", 0x4a, 2), ("CORBCTL", 0x4c, 1), ("CORBSTS", 0x4d, 1),
	("CORBSIZE", 0x4e, 1),
	("RIRBLBASE", 0x50, 4), ("RIRBUBASE", 0x54, 4), ("RIRBWP", 0x58, 2),
	("RINTCNT", 0x5a, 2), ("RIRBCTL", 0x5c, 1), ("RIRBSTS", 0x5d, 1),
	("RIRBSIZE", 0x5e, 1),
	("IC", 0x60, 4), ("IR", 0x64, 4), ("ICS", 0x68, 2),
	("DPLBASE", 0x70, 4), ("DPUBASE", 0x74, 4),
]
OFF = {name: off for name, off, _ in REGS}

GCTL_CRST = 1 << 0
GCTL_UNSOL = 1 << 8
ICS_ICB = 1 << 0
ICS_IRV = 1 << 1
CORBCTL_RUN = 1 << 1
RIRBCTL_DMAEN = 1 << 1
STATESTS_MASK = 0x7fff

VERBS = {
	"GET_PARAMETER": 0xf00, "PARAMETERS": 0xf00,
	"GET_CONNECT_SEL": 0xf01, "GET_CONNECT_LIST": 0xf02,
	"GET_POWER_STATE": 0xf05, "SET_POWER_STATE": 0x705,
	"GET_PIN_WIDGET_CONTROL": 0xf07, "GET_EAPD_BTLENABLE": 0xf0c,
	"GET_GPIO_DATA": 0xf15, "SET_GPIO_DATA": 0x715,
	"GET_GPIO_MASK": 0xf16, "SET_GPIO_MASK": 0x716,
	"GET_GPIO_DIRECTION": 0xf17, "SET_GPIO_DIRECTION": 0x717,
	"GET_CONFIG_DEFAULT": 0xf1c, "GET_SUBSYSTEM_ID": 0xf20,
	"FUNCTION_RESET": 0x7ff,
}
PARAMS = {
	"VENDOR_ID": 0x00, "SUBSYSTEM_ID": 0x01, "REV_ID": 0x02,
	"NODE_COUNT": 0x04, "FUNCTION_TYPE": 0x05, "AUDIO_FG_CAP": 0x08,
	"AUDIO_WIDGET_CAP": 0x09, "PCM": 0x0a, "STREAM": 0x0b,
	"PIN_CAP": 0x0c, "AMP_IN_CAP": 0x0d, "CONNLIST_LEN": 0x0e,
	"POWER_STATE": 0x0f, "PROC_CAP": 0x10, "GPIO_CAP": 0x11,
	"AMP_OUT_CAP": 0x12, "VOL_KNB_CAP": 0x13,
}


class ToolError(Exception):
	pass


def log(msg=""):
	print(msg, flush=True)


def hexw(val, width):
	return "0x%0*x" % (width * 2, val)


def bits(val, names):
	"""Return the names of the set bits, from a {bit: name} map."""
	on = [n for b, n in sorted(names.items()) if val & (1 << b)]
	return ",".join(on) if on else "-"


def norm_bdf(bdf):
	if bdf.count(":") == 1:
		bdf = "0000:" + bdf
	if not os.path.isdir(os.path.join(SYSFS_PCI, bdf)):
		raise ToolError("no PCI device %s in %s" % (bdf, SYSFS_PCI))
	return bdf


class PciDev:
	"""PCI config space access through sysfs."""

	def __init__(self, bdf):
		self.bdf = bdf
		self.path = os.path.join(SYSFS_PCI, bdf)

	def sysfs(self, name):
		try:
			with open(os.path.join(self.path, name)) as f:
				return f.read().strip()
		except OSError:
			return None

	def driver(self):
		link = os.path.join(self.path, "driver")
		return os.path.basename(os.readlink(link)) if os.path.islink(link) else None

	def cfg(self, off, width):
		with open(os.path.join(self.path, "config"), "rb") as f:
			data = os.pread(f.fileno(), width, off)
		if len(data) != width:
			raise ToolError("config read at 0x%x failed (not root?)" % off)
		return int.from_bytes(data, "little")

	def cfg_write(self, off, width, val):
		with open(os.path.join(self.path, "config"), "r+b", buffering=0) as f:
			os.pwrite(f.fileno(), val.to_bytes(width, "little"), off)

	def pm_state(self):
		"""Return the D-state from the PM capability, or None."""
		try:
			if not self.cfg(0x06, 2) & (1 << 4):
				return None
			ptr, seen = self.cfg(0x34, 1) & 0xfc, 0
			while ptr and seen < 48:
				if self.cfg(ptr, 1) == 0x01:
					return self.cfg(ptr + 4, 2) & 0x3
				ptr, seen = self.cfg(ptr + 1, 1) & 0xfc, seen + 1
		except ToolError:
			pass
		return None


class Bar:
	"""One memory BAR, mapped with exact-width accesses.

	A memoryview cast gives one load or store of the correct width per access.
	"""

	def __init__(self, pci, index, writable):
		path = os.path.join(pci.path, "resource%d" % index)
		flags = (os.O_RDWR if writable else os.O_RDONLY) | os.O_SYNC
		try:
			fd = os.open(path, flags)
		except FileNotFoundError:
			raise ToolError("%s does not exist (BAR%d is not a memory BAR?)" % (path, index))
		except PermissionError:
			raise ToolError("cannot open %s (run as root)" % path)
		try:
			self.size = os.fstat(fd).st_size
			if self.size < 0x80:
				raise ToolError("BAR%d is too small (%d bytes)" % (index, self.size))
			prot = mmap.PROT_READ | (mmap.PROT_WRITE if writable else 0)
			self.mm = mmap.mmap(fd, self.size, mmap.MAP_SHARED, prot)
		finally:
			os.close(fd)
		mv = memoryview(self.mm)
		self.views = {1: mv, 2: mv.cast("H"), 4: mv.cast("I")}

	def check(self, off, width):
		if width not in self.views or off % width or off + width > self.size:
			raise ToolError("bad access: offset 0x%x width %d" % (off, width))

	def read(self, off, width):
		self.check(off, width)
		return self.views[width][off // width]

	def write(self, off, width, val):
		self.check(off, width)
		self.views[width][off // width] = val & ((1 << (8 * width)) - 1)
		# Read back so that the ASM1083 bridge never gets a burst of posted writes.
		self.views[width][off // width]


class Hda:
	def __init__(self, bar, args):
		self.bar = bar
		self.args = args

	def r(self, name):
		_, off, width = next(r for r in REGS if r[0] == name)
		return self.bar.read(off, width)

	def w(self, name, val):
		_, off, width = next(r for r in REGS if r[0] == name)
		self.bar.write(off, width, val)

	def poll(self, name, cond, timeout_ms):
		"""Read a register until cond(value) is true. Return (ok, value, ms)."""
		t0 = time.monotonic()
		deadline = t0 + timeout_ms / 1000.0
		while True:
			val = self.r(name)
			now = time.monotonic()
			if cond(val):
				return True, val, (now - t0) * 1000.0
			if now >= deadline:
				return False, val, (now - t0) * 1000.0
			time.sleep(self.args.poll_us / 1e6)

	def alive(self):
		gcap = self.r("GCAP")
		return gcap not in (0x0000, 0xffff), gcap

	def stop_cmd_dma(self):
		"""Stop CORB/RIRB DMA if it runs. IC must not run with CORB/RIRB."""
		for reg, bit in (("RIRBCTL", RIRBCTL_DMAEN), ("CORBCTL", CORBCTL_RUN)):
			val = self.r(reg)
			if val & bit:
				log("  %s=0x%02x: DMA runs, stop it" % (reg, val))
				self.w(reg, val & ~bit)
				ok, val, _ = self.poll(reg, lambda v, b=bit: not v & b, 100)
				if not ok:
					log("  WARNING: %s DMA bit stays set (0x%02x)" % (reg, val))

	def reset(self):
		"""Controller reset like snd_hdac_bus_reset_link(). Return STATESTS."""
		a = self.args
		log("reset: GCTL=0x%08x STATESTS=0x%04x before reset" % (self.r("GCTL"), self.r("STATESTS")))
		self.stop_cmd_dma()
		if self.r("GCTL") & GCTL_CRST:
			self.w("STATESTS", STATESTS_MASK)
		self.w("GCTL", self.r("GCTL") & ~GCTL_CRST)
		ok, val, ms = self.poll("GCTL", lambda v: not v & GCTL_CRST, a.reset_timeout_ms)
		log("reset: enter reset: %s after %.3f ms (GCTL=0x%08x)" % ("ok" if ok else "TIMEOUT", ms, val))
		if not ok:
			raise ToolError("GCTL.CRST does not go to 0")
		time.sleep(0.001)
		self.w("GCTL", self.r("GCTL") | GCTL_CRST)
		ok, val, ms = self.poll("GCTL", lambda v: v & GCTL_CRST, a.reset_timeout_ms)
		log("reset: exit reset: %s after %.3f ms (GCTL=0x%08x)" % ("ok" if ok else "TIMEOUT", ms, val))
		if not ok:
			raise ToolError("GCTL.CRST does not go to 1")
		# The kernel reads STATESTS 1 ms after reset. Then look for late codecs.
		time.sleep(0.001)
		early = self.r("STATESTS")
		deadline = time.monotonic() + a.settle_ms / 1000.0
		late = early
		while time.monotonic() < deadline:
			time.sleep(0.001)
			late |= self.r("STATESTS")
		log("reset: STATESTS=0x%04x at 1 ms (kernel codec_mask), 0x%04x after %d ms" % (early, late, a.settle_ms))
		if late & ~early:
			log("reset: NOTE: codec(s) 0x%04x appear late; the kernel does not see them" % (late & ~early))
		if late == 0xffff:
			raise ToolError("STATESTS reads 0xffff: the BAR does not respond")
		self.w("GCTL", self.r("GCTL") | GCTL_UNSOL)
		return late & STATESTS_MASK

	def abort(self):
		"""Write ICB=0 to stop a command that gets no response."""
		self.w("ICS", 0)
		ok, ics, _ = self.poll("ICS", lambda v: not v & ICS_ICB, 10)
		if ok:
			return "abort: ICB is 0 again"
		return "abort: ICB stays 1 (ICS=0x%04x), reset the controller" % ics

	def verb(self, cmd):
		"""Send one verb through IC/IR/ICS. Return (ok, response, message)."""
		t = self.args.timeout_ms
		ok, ics, ms = self.poll("ICS", lambda v: not v & ICS_ICB, t)
		if not ok:
			return False, None, "ICB stays busy before the command (ICS=0x%04x)" % ics
		self.w("ICS", ICS_IRV)  # IRV is write-1-to-clear. ICB=0 here.
		self.w("IC", cmd)
		self.w("ICS", ICS_ICB)
		ok, ics, ms = self.poll("ICS", lambda v: v & ICS_IRV, t)
		if not ok:
			if ics == 0xffff:
				why = "ICS reads 0xffff: the BAR does not respond"
			elif ics & ICS_ICB:
				why = "no response: ICB stays 1, IRV stays 0 (the codec does not answer)"
			else:
				why = "ICB goes to 0 but IRV stays 0 (the response is lost)"
			msg = "%s after %.1f ms (ICS=0x%04x)" % (why, ms, ics)
			if ics != 0xffff and ics & ICS_ICB:
				msg += "; " + self.abort()
			return False, None, msg
		res = self.r("IR")
		self.w("ICS", ICS_IRV)
		info = "%.3f ms, ICS=0x%04x" % (ms, ics)
		if ics & (1 << 3):
			info += ", unsolicited"
		info += ", from addr %d" % ((ics >> 4) & 0xf)
		return True, res, info


def make_cmd(addr, nid, verb, param):
	if not 0 <= addr <= 0xe:
		raise ToolError("codec address must be 0..14")
	if not 0 <= nid <= 0x7f:
		raise ToolError("NID must be 0..0x7f")
	if not 0 <= verb <= 0xfff:
		raise ToolError("verb must be 12 bits (4-bit verbs: 0x200, 0x300, ...)")
	if not 0 <= param <= 0xffff or (verb & 0xff and param > 0xff):
		raise ToolError("payload too large: 8 bits for a 12-bit verb, 16 bits for a 4-bit verb")
	return (addr << 28) | (nid << 20) | (verb << 8) | param


def parse_num(text, names=None):
	if names and text.upper() in names:
		return names[text.upper()]
	try:
		return int(text, 0)
	except ValueError:
		raise ToolError("bad number or name: %r" % text)


def print_pci(pci):
	cmd, sts = pci.cfg(0x04, 2), pci.cfg(0x06, 2)
	log("PCI %s: id %04x:%04x subsys %04x:%04x rev %02x class %06x driver %s" % (
		pci.bdf, pci.cfg(0x00, 2), pci.cfg(0x02, 2), pci.cfg(0x2c, 2),
		pci.cfg(0x2e, 2), pci.cfg(0x08, 1), pci.cfg(0x08, 4) >> 8,
		pci.driver() or "none"))
	log("  COMMAND 0x%04x [%s]" % (cmd, bits(cmd, {0: "IO", 1: "MEM", 2: "BUSMASTER", 6: "PARITY", 8: "SERR", 10: "INTX_DISABLE"})))
	log("  STATUS  0x%04x [%s]" % (sts, bits(sts, {3: "INTX", 4: "CAPLIST", 8: "MDPE", 11: "SIG_TABORT", 12: "RCV_TABORT", 13: "RCV_MABORT", 14: "SIG_SERR", 15: "PARITY_ERR"})))
	log("  BAR0 0x%08x  IRQ line %d pin %d  power %s" % (
		pci.cfg(0x10, 4), pci.cfg(0x3c, 1), pci.cfg(0x3d, 1),
		{None: "unknown", 0: "D0", 1: "D1", 2: "D2", 3: "D3hot"}[pci.pm_state()]))
	if not cmd & 0x2:
		log("  WARNING: memory decoding is off: BAR reads give 0xffffffff (use --enable-mem)")
	if not cmd & 0x4:
		log("  NOTE: bus master is off. IC/IR does not need it, CORB/RIRB DMA does.")
	if sts & (0x7 << 11):
		log("  WARNING: an abort bit is set in STATUS (a transaction failed)")
	return cmd


def decode(name, val):
	"""Return a short decode of one register value."""
	if name == "GCAP":
		return "64OK=%d NSDO=%d BSS=%d ISS=%d OSS=%d" % (
			val & 1, (val >> 1) & 3, (val >> 3) & 0x1f, (val >> 8) & 0xf, (val >> 12) & 0xf)
	if name == "GCTL":
		return bits(val, {0: "CRST", 1: "FCNTRL", 8: "UNSOL"}) + ("" if val & 1 else "  (controller in reset)")
	if name == "STATESTS":
		return "codec mask, addrs [%s]" % ",".join(str(i) for i in range(15) if val & (1 << i))
	if name in ("INTCTL", "INTSTS"):
		top = {"INTCTL": ("GIE", "CIE"), "INTSTS": ("GIS", "CIS")}[name]
		return "%s=%d %s=%d streams=0x%08x" % (top[0], val >> 31, top[1], (val >> 30) & 1, val & 0x3fffffff)
	if name in ("CORBRP", "RIRBWP"):
		return "ptr=%d%s" % (val & 0xff, " RST" if val & 0x8000 else "")
	if name == "CORBWP":
		return "ptr=%d" % (val & 0xff)
	if name == "CORBCTL":
		return bits(val, {0: "CMEIE", 1: "CORBRUN"})
	if name == "CORBSTS":
		return bits(val, {0: "CMEI"})
	if name == "RIRBCTL":
		return bits(val, {0: "RINTCTL", 1: "RIRBDMAEN", 2: "RIRBOIC"})
	if name == "RIRBSTS":
		return bits(val, {0: "RINTFL", 2: "RIRBOIS"})
	if name in ("CORBSIZE", "RIRBSIZE"):
		caps = [str(n) for b, n in ((4, 2), (5, 16), (6, 256)) if val & (1 << b)]
		return "size=%s cap=[%s]" % ({0: "2", 1: "16", 2: "256"}.get(val & 3, "?"), ",".join(caps))
	if name == "RINTCNT":
		return "count=%d" % ((val & 0xff) or 256)
	if name == "ICS":
		return "%s IRRADD=%d" % (bits(val, {0: "ICB", 1: "IRV", 2: "ICVER", 3: "IRRUNSOL"}), (val >> 4) & 0xf)
	if name == "DPLBASE":
		return bits(val, {0: "ENABLE"})
	return ""


def cmd_dump(hda, pci, args):
	alive, gcap = hda.alive()
	log("Registers of %s (BAR0, %d bytes):" % (pci.bdf, hda.bar.size))
	for name, off, width in REGS:
		val = hda.bar.read(off, width)
		log("  %-9s @0x%02x = %-10s %s" % (name, off, hexw(val, width), decode(name, val)))
	if not alive:
		log("dump: GCAP=0x%04x: the BAR does not respond or the device is off" % gcap)
		return 1
	nstreams = min(((gcap >> 8) & 0xf) + ((gcap >> 12) & 0xf) + ((gcap >> 3) & 0x1f), 30)
	log("Streams (%d):" % nstreams)
	for i in range(nstreams):
		base = 0x80 + 0x20 * i
		if base + 0x20 > hda.bar.size:
			break
		ctl = hda.bar.read(base, 4)
		log("  SD%-2d @0x%03x CTL=0x%06x STS=0x%02x LPIB=0x%08x CBL=0x%08x LVI=%d FMT=0x%04x BDL=0x%08x%08x%s" % (
			i, base, ctl & 0xffffff, ctl >> 24, hda.bar.read(base + 4, 4),
			hda.bar.read(base + 8, 4), hda.bar.read(base + 0xc, 2) & 0xff,
			hda.bar.read(base + 0x12, 2), hda.bar.read(base + 0x1c, 4),
			hda.bar.read(base + 0x18, 4), "  RUN" if ctl & 2 else ""))
	log("dump: OK, GCAP=0x%04x" % gcap)
	return 0


def cmd_reset(hda, pci, args):
	mask = hda.reset()
	log("reset: OK, STATESTS=0x%04x" % mask)
	return 0


def cmd_verb(hda, pci, args):
	cmd = make_cmd(parse_num(args.addr), parse_num(args.nid),
		       parse_num(args.verb, VERBS), parse_num(args.param, PARAMS))
	hda.stop_cmd_dma()
	ok, res, info = hda.verb(cmd)
	if not ok:
		log("verb 0x%08x: FAIL: %s" % (cmd, info))
		return 2
	log("verb 0x%08x -> 0x%08x (%s)" % (cmd, res, info))
	return 0


def get_param(hda, addr, nid, param):
	ok, res, info = hda.verb(make_cmd(addr, nid, 0xf00, param))
	return res if ok else None, info


def describe_codec(hda, addr):
	"""Query one codec with GET_PARAMETER. Return the vendor ID or None."""
	vid, info = get_param(hda, addr, 0, 0x00)
	if vid is None:
		log("codec %d: vendor id: FAIL: %s" % (addr, info))
		return None
	log("codec %d: vendor id 0x%08x (vendor 0x%04x device 0x%04x) [%s]" % (addr, vid, vid >> 16, vid & 0xffff, info))
	if vid in (0, 0xffffffff):
		log("codec %d: WARNING: vendor id 0x%08x is not valid" % (addr, vid))
		return None
	rev, _ = get_param(hda, addr, 0, 0x02)
	cnt, _ = get_param(hda, addr, 0, 0x04)
	log("codec %d: revision %s" % (addr, "0x%08x" % rev if rev is not None else "FAIL"))
	if cnt is None:
		log("codec %d: node count: FAIL" % addr)
		return vid
	start, num = (cnt >> 16) & 0xff, cnt & 0xff
	log("codec %d: function groups: start nid 0x%02x, count %d" % (addr, start, num))
	for nid in range(start, start + min(num, 8)):
		ftype, _ = get_param(hda, addr, nid, 0x05)
		sub, _ = get_param(hda, addr, nid, 0x04)
		gpio, _ = get_param(hda, addr, nid, 0x11)
		ok, ssid, _ = hda.verb(make_cmd(addr, nid, 0xf20, 0))
		ok2, pwr, _ = hda.verb(make_cmd(addr, nid, 0xf05, 0))
		kind = {1: "AFG", 2: "MFG"}.get(ftype & 0xff, "?") if ftype is not None else "FAIL"
		log("codec %d:  nid 0x%02x %s type=%s subsystem=%s widgets=%s gpio_cap=%s power=%s" % (
			addr, nid, kind,
			"0x%08x" % ftype if ftype is not None else "FAIL",
			"0x%08x" % ssid if ok else "FAIL",
			"start 0x%02x count %d" % ((sub >> 16) & 0xff, sub & 0xff) if sub is not None else "FAIL",
			"0x%08x" % gpio if gpio is not None else "FAIL",
			"set D%d act D%d" % (pwr & 3, (pwr >> 4) & 3) if ok2 else "FAIL"))
	return vid


def cmd_probe(hda, pci, args):
	if args.no_reset:
		mask = hda.r("STATESTS") & STATESTS_MASK
		log("probe: no reset, STATESTS=0x%04x" % mask)
	else:
		mask = hda.reset()
	hda.stop_cmd_dma()
	if args.addr:
		addrs = [parse_num(a) for a in args.addr.split(",")]
	elif mask:
		addrs = [i for i in range(15) if mask & (1 << i)]
	elif args.all:
		addrs = list(range(15))
	else:
		log("probe: FAIL: no codec in STATESTS (use --all to query all addresses)")
		return 2
	log("probe: query codec address(es) %s with the immediate command interface" % addrs)
	good = 0
	for addr in addrs:
		if hda.r("ICS") & ICS_ICB and not args.no_reset:
			log("probe: ICB stays 1 from the last command: reset the controller")
			hda.reset()
		vid = describe_codec(hda, addr)
		if vid is not None:
			good += 1
			log("FOUND: codec %d vendor_id 0x%08x" % (addr, vid))
	if not good:
		log("probe: FAIL: no codec gave a valid vendor id")
		return 2
	log("probe: %d codec(s) gave a valid vendor id" % good)
	return 0


def cmd_read(hda, pci, args):
	off, width = parse_num(args.off), parse_num(args.width)
	log("BAR%d[0x%x] = %s" % (args.bar, off, hexw(hda.bar.read(off, width), width)))
	return 0


def cmd_write(hda, pci, args):
	off, val, width = parse_num(args.off), parse_num(args.val), parse_num(args.width)
	hda.bar.write(off, width, val)
	log("BAR%d[0x%x] <- %s, read back %s" % (args.bar, off, hexw(val, width), hexw(hda.bar.read(off, width), width)))
	return 0


CORB_NOTE = """corb: not done here.
CORB/RIRB needs a DMA buffer with a known bus address. Userspace cannot get
one without a driver (vfio or a kernel module). The kernel debug patch covers
this path: load snd-hda-intel with ae7_debug=1. It prints the CORB/RIRB
registers and the first ring entries before and after the codec probe and at
each response timeout. Compare CORBRP (the controller read the command) with
RIRBWP (the controller wrote a response) and the RIRB words in memory."""


def main():
	if sys.argv[1:] == ["corb"]:
		log(CORB_NOTE)
		return 0
	ap = argparse.ArgumentParser(
		description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	ap.add_argument("bdf", help="PCI address, e.g. 0000:00:05.0")
	ap.add_argument("--enable-mem", action="store_true",
			help="set COMMAND.MEM if it is off (writes PCI config)")
	ap.add_argument("--enable-master", action="store_true",
			help="set COMMAND.BUSMASTER if it is off (not needed for IC/IR)")
	ap.add_argument("--force", action="store_true",
			help="write registers even if a driver is bound")
	ap.add_argument("--bar", type=int, default=0, help="BAR for read/write (default 0)")
	ap.add_argument("--timeout-ms", type=float, default=50.0,
			help="timeout per wait in a verb (default 50)")
	ap.add_argument("--reset-timeout-ms", type=float, default=100.0,
			help="timeout for each CRST change (default 100, as the kernel)")
	ap.add_argument("--settle-ms", type=int, default=20,
			help="time to look for late STATESTS bits after reset (default 20)")
	ap.add_argument("--poll-us", type=float, default=20.0,
			help="sleep between two register polls (default 20)")
	ap.add_argument("--no-reset", action="store_true",
			help="probe: do not reset the controller first")
	ap.add_argument("--addr", help="probe: comma-separated codec addresses (skip STATESTS)")
	ap.add_argument("--all", action="store_true",
			help="probe: query addresses 0..14 if STATESTS is 0")
	sub = ap.add_subparsers(dest="cmd", required=True)
	sub.add_parser("dump", help="decode all controller registers")
	sub.add_parser("reset", help="controller reset, report STATESTS")
	p = sub.add_parser("verb", help="one immediate command")
	p.add_argument("addr")
	p.add_argument("nid")
	p.add_argument("verb", help="12-bit verb (number or name, e.g. GET_PARAMETER)")
	p.add_argument("param", help="payload (number or parameter name, e.g. VENDOR_ID)")
	sub.add_parser("probe", help="reset, then query each codec in STATESTS")
	p = sub.add_parser("read", help="read one register")
	p.add_argument("off")
	p.add_argument("width", nargs="?", default="4")
	p = sub.add_parser("write", help="write one register")
	p.add_argument("off")
	p.add_argument("val")
	p.add_argument("width", nargs="?", default="4")
	sub.add_parser("corb", help="explain the CORB/RIRB test")
	args = ap.parse_args()

	if args.cmd == "corb":
		log(CORB_NOTE)
		return 0
	pci = PciDev(norm_bdf(args.bdf))
	cmd = print_pci(pci)
	want = (0x2 if args.enable_mem else 0) | (0x4 if args.enable_master else 0)
	if want & ~cmd:
		pci.cfg_write(0x04, 2, cmd | want)
		log("  COMMAND 0x%04x -> 0x%04x (enabled on request)" % (cmd, pci.cfg(0x04, 2)))
	writes = args.cmd in ("reset", "verb", "probe", "write")
	drv = pci.driver()
	if writes and drv and not args.force:
		raise ToolError("driver %s is bound to %s; unbind it or use --force" % (drv, pci.bdf))
	bar = Bar(pci, args.bar if args.cmd in ("read", "write") else 0, writes)
	hda = Hda(bar, args)
	if args.cmd in ("reset", "verb", "probe"):
		alive, gcap = hda.alive()
		if not alive:
			raise ToolError("GCAP=0x%04x: the BAR does not respond, no writes done" % gcap)
	handler = {"dump": cmd_dump, "reset": cmd_reset, "verb": cmd_verb,
		   "probe": cmd_probe, "read": cmd_read, "write": cmd_write}[args.cmd]
	return handler(hda, pci, args)


if __name__ == "__main__":
	try:
		sys.exit(main())
	except ToolError as e:
		print("hda-mmio: error: %s" % e, file=sys.stderr, flush=True)
		sys.exit(1)
