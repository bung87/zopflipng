include nimPNG
include nimPNG/nimz
import streams
import sequtils

# const WindowSizeMax = 32768
const WindowSizeTry = 8192

proc makePNGEncoder(filterStrategy: PNGFilterStrategy; modeIn: PNGColorMode; predefinedFilters: seq[PNGFilter];
    autoConvert = true; modeOut: PNGColorMode = newColorMode()): PNGEncoder =
  var s = new PNGEncoder
  s.filterPaletteZero = true
  s.filterStrategy = filterStrategy
  s.autoConvert = autoConvert
  s.modeIn = modeIn
  s.modeOut = modeOut
  s.forcePalette = false
  if filterStrategy == LFS_PREDEFINED:
    # Don't forget that filter_palette_zero must be set to false to ensure this is also used on palette or low bitdepth images.
    s.predefinedFilters = predefinedFilters
    s.filterPaletteZero = false
  else:
    s.predefinedFilters = @[]
  s.addID = false
  s.textCompression = true
  s.interlaceMethod = IM_NONE
  # s.backgroundDefined = false
  # s.backgroundR = 0
  # s.backgroundG = 0
  # s.backgroundB = 0
  # s.physDefined = false
  # s.physX = 0
  # s.physY = 0
  # s.physUnit = 0
  # s.timeDefined = false
  # s.textList = @[]
  # s.itextList = @[]
  # s.unknown = @[]
  # s.numPlays = 0
  result = s


const ChunksNeedWrite = [IHDR, IDAT, PLTE, tRNS, IEND]

proc nzInitMy(windowSize: int): nzStream =
  # const DEFAULT_WINDOWSIZE = 2048

  result = nzStream(
    #compress with dynamic huffman tree
      #(not in the mathematical sense, just not the predefined one)
    btype: nzDynamic,
    use_lz77: true,
    windowsize: windowSize,
    minmatch: 3,
    nicematch: 258, # default 128, max 258 for getting smaller size
    lazymatching: true,
    ignoreAdler32: false)

proc nzDeflateInitMy(input: string; winSize: int): nzStream =
  var nz = nzInitMy(winSize)
  nz.data = input
  nz.bits.data = ""
  nz.bits.bitpointer = 0
  nz.mode = nzsDeflate
  result = nz

proc writeChunk(chunk: PNGICCProfile; png: PNG; winSize: int): bool =
  #estimate chunk.profileName.len + 2
  chunk.writeString chunk.profileName
  chunk.writeByte 0 #null separator
  chunk.writeByte 0 #compression proc(0: deflate)
  var nz = nzDeflateInit(chunk.profile)
  chunk.writeString zlib_compress(nz)
  result = true

proc writeChunk(chunk: PNGData; png: PNG; winSize: int): bool =
  var nz = nzDeflateInitMy(chunk.idat, winSIze)
  chunk.data = zlib_compress(nz)
  result = true

proc writeChunk(chunk: PNGChunk; png: PNG; winSize: int): bool =
  case chunk.chunkType
  of IHDR: result = writeChunk(PNGHeader(chunk), png)
  of PLTE: result = writeChunk(PNGPalette(chunk), png)
  of IDAT: result = writeChunk(PNGData(chunk), png, winSize)
  of tRNS: result = writeChunk(PNGTrans(chunk), png)
  of bKGD: result = writeChunk(PNGBackground(chunk), png)
  of tIME: result = writeChunk(PNGTime(chunk), png)
  of pHYs: result = writeChunk(PNGPhys(chunk), png)
  of tEXt: result = writeChunk(PNGTExt(chunk), png)
  of zTXt: result = writeChunk(PNGZtxt(chunk), png)
  of iTXt: result = writeChunk(PNGItxt(chunk), png)
  of gAMA: result = writeChunk(PNGGamma(chunk), png)
  of cHRM: result = writeChunk(PNGChroma(chunk), png)
  of iCCP: result = writeChunk(PNGICCProfile(chunk), png, winSize)
  of sRGB: result = writeChunk(PNGStandarRGB(chunk), png)
  of sPLT: result = writeChunk(PNGSPalette(chunk), png)
  of hIST: result = writeChunk(PNGHist(chunk), png)
  of sBIT: result = writeChunk(PNGSbit(chunk), png)
  of acTL: result = writeChunk(APNGAnimationControl(chunk), png)
  of fcTL: result = writeChunk(APNGFrameControl(chunk), png)
  of fdAT: result = writeChunk(APNGFrameData(chunk), png)
  else: result = true

proc writeNeededChunks[T](png: PNG[T]; s: Stream) =
  s.write PNGSignature
  for chunk in png.chunks:
    if ChunksNeedWrite.find(chunk.chunkType) == -1:
      continue
    if not chunk.validateChunk(png): raise PNGFatal("combine chunk validation error " & $chunk.chunkType)
    if not chunk.writeChunk(png, WindowSizeTry): raise PNGFatal("combine chunk write error " & $chunk.chunkType)
    chunk.length = chunk.data.len
    chunk.crc = crc32(crc32(0, $chunk.chunkType), chunk.data)

    s.writeInt32BE chunk.length
    s.writeInt32BE int(chunk.chunkType)
    s.write chunk.data
    s.writeInt32BE cast[int](chunk.crc)

proc optimizePNG*[T](png: PNG[T]; bsize: int; dest: string) =
  let info = png.getInfo()
  let predefinedFilters = png.getFilterTypes()
  var bestData: string
  var ss: StringStream
  var settings: PNGEncoder
  var pngTemp: PNG[T]
  var choosedPNGColorMode: PNGColorMode
  var choosen = false

  for filterStrategy in PNGFilterStrategy:
    if LFS_BRUTE_FORCE == filterStrategy or LFS_ZERO == filterStrategy:
      continue
    ss = newStringStream()
    if choosen:
      settings = makePNGEncoder(filterStrategy, info.mode, predefinedFilters, false, choosedPNGColorMode)
    else:
      settings = makePNGEncoder(filterStrategy, info.mode, predefinedFilters)
    pngTemp = encodePNG[T](png.pixels, settings.modeOut.colorType, settings.modeOut.bitDepth, info.width,
        info.height, settings = settings)
    if not choosen:
      choosedPNGColorMode = settings.modeOut
      choosen = true
    pngTemp.writeNeededChunks(ss)
    # Keep the smallest result
    if bestData.len == 0 or ss.data.len < bestData.len:
      when declared(shallowCopy):
        bestData.shallowCopy ss.data
      else:
        bestData = ss.data

  for f in PNGFilter:
    ss = newStringStream()
    let filters = newSeqWith(info.height, f)
    if choosen:
      settings = makePNGEncoder(LFS_PREDEFINED, info.mode, filters, false, choosedPNGColorMode)
    else:
      settings = makePNGEncoder(LFS_PREDEFINED, info.mode, filters)
    pngTemp = encodePNG(png.pixels, settings.modeOut.colorType, settings.modeOut.bitDepth, info.width, info.height,
        settings = settings)
    if not choosen:
      choosedPNGColorMode = settings.modeOut
      choosen = true
    pngTemp.writeNeededChunks(ss)
    # Keep the smallest result
    if bestData.len == 0 or ss.data.len < bestData.len:
      when declared(shallowCopy):
        bestData.shallowCopy ss.data
      else:
        bestData = ss.data

  if bestData.len == 0:
    raise newException(IOError, "No valid PNG output generated")

  writeFile(dest, bestData)

proc optimizePNGData*(bytes: seq[byte]; dest: string) =
  var data = cast[string](bytes)
  let png = decodePNG(newStringStream(data))
  optimizePNG[string](png, data.len, dest)

proc optimizePNG*(src, dest: string) =
  let f = open(src, fmRead)
  var data = f.readAll
  f.close
  optimizePNGData(cast[seq[byte]](data), dest)

when isMainModule:
  let src = "logo.png"
  let dest = "logo_out.png"
  optimizePNG(src, dest)
