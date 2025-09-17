local LrTasks         = import 'LrTasks'
local LrDialogs       = import 'LrDialogs'
local LrPathUtils     = import 'LrPathUtils'
local LrExportSession = import 'LrExportSession'
local LrFileUtils     = import 'LrFileUtils'
local LrView          = import 'LrView'
local LrBinding       = import 'LrBinding'
local LrProgressScope = import 'LrProgressScope'

local bind = LrView.bind
local exportServiceProvider = {}

-- =========================
-- Presets & helpers
-- =========================
exportServiceProvider.exportPresetFields = {
  { key = 'imageQuality',   default = 70 },
  { key = 'conversionTool', default = 'ghdr' }, -- UI parity / legacy

  -- toGainMapHDR options
  { key = 'gm_mode',        default = 'apple_cif' }, -- iso|apple_cif|apple_iso|sdr|pq|hlg
  { key = 'sdrRatio',       default = 0.20 },        -- -r (0.00..1.00)
  { key = 'colorSpace',     default = 'p3' },        -- -c
  { key = 'bitDepth',       default = 10 },          -- -d
  { key = 'container',      default = 'heic' },      -- heic|jpeg  (-j for jpeg)
  { key = 'fileSuffix',     default = '' },          -- -t

  -- New, user-facing size control (maps to wrapper ratio via ratio = 1/size)
  { key = 'uiGainMapSize',  default = 1.00 },        -- 1.00×..0.50×

  -- Legacy ratio (wrapper expects -H 1.00..2.00). Kept for back-compat only.
  { key = 'gainMapScale',   default = 1.50 },
}

local function clamp(v, lo, hi)
  v = tonumber(v) or lo
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function clampQuality(q)
  return clamp(math.floor((tonumber(q) or 70) + 0.5), 0, 100)
end

-- Shell-quote (defensive)
local function q(s) return '"' .. tostring(s):gsub('\\', '\\\\'):gsub('"','\\"') .. '"' end

-- 2-decimal binding for edit_field; keeps underlying value numeric (rounded)
local function decimalBinding(key, decimals, min, max)
  decimals = decimals or 2
  local fmt    = "%." .. tostring(decimals) .. "f"
  local factor = 10 ^ decimals

  return LrView.bind {
    key = key,
    transform = function(v)
      v = tonumber(v) or 0
      return string.format(fmt, v)
    end,
    reverseTransform = function(s)
      local n = tonumber(s)
      if not n then return nil end
      if min then n = math.max(min, n) end
      if max then n = math.min(max, n) end
      return math.floor(n * factor + 0.5) / factor
    end
  }
end

-- Prefer lrgainmap, then ghdr
local function resolveWrapper()
  local binDir = LrPathUtils.child(_PLUGIN.path, "bin")
  local w1 = LrPathUtils.child(binDir, "lrgainmap")
  local w2 = LrPathUtils.child(binDir, "ghdr")
  if LrFileUtils.exists(w1) == 'file' then return w1 end
  if LrFileUtils.exists(w2) == 'file' then return w2 end
  return nil
end

-- =========================
-- UI
-- =========================
exportServiceProvider.sectionsForTopOfDialog = function(viewFactory, propertyTable)
  local f = viewFactory

  -- Ensure defaults exist BEFORE observers/conditions
  propertyTable.imageQuality   = clampQuality(propertyTable.imageQuality)
  propertyTable.gm_mode        = propertyTable.gm_mode        or 'apple_cif'
  propertyTable.sdrRatio       = tonumber(propertyTable.sdrRatio) or 0.20
  propertyTable.colorSpace     = propertyTable.colorSpace     or 'p3'
  propertyTable.bitDepth       = tonumber(propertyTable.bitDepth) or 10
  propertyTable.container      = propertyTable.container      or 'heic'
  propertyTable.fileSuffix     = propertyTable.fileSuffix     or ''

  -- Back-compat: if uiGainMapSize not set yet, derive from legacy gainMapScale
  -- wrapper ratio (-H) = 1.00..2.00  <=>  UI size (×) = 1/ratio = 1.00..0.50
  do
    local ui = tonumber(propertyTable.uiGainMapSize)
    if not ui then
      local legacyRatio = tonumber(propertyTable.gainMapScale) or 1.50
      local derivedSize = 1.0 / legacyRatio
      propertyTable.uiGainMapSize = clamp(derivedSize, 0.50, 1.00)
    else
      propertyTable.uiGainMapSize = clamp(ui, 0.50, 1.00)
    end
  end

  -- Auto-tune bitDepth for PQ/HLG (10-bit)
  propertyTable:addObserver('gm_mode', function()
    local m = propertyTable.gm_mode
    if m == 'pq' or m == 'hlg' then propertyTable.bitDepth = 10 end
  end)

  propertyTable:addObserver('imageQuality', function()
    propertyTable.imageQuality = clampQuality(propertyTable.imageQuality)
  end)


    local function appleModeEnabledBinding()
    return LrView.bind {
        key = 'gm_mode',
        transform = function(mode)
        return mode == 'apple_cif' or mode == 'apple_iso'
        end
    }
    end

    local function bitDepthEnabledBinding()
    return LrView.bind {
        key = 'gm_mode',
        transform = function(mode)
        return not (mode == 'pq' or mode == 'hlg')
        end
    }
    end


  return {
    {
      title = "HEIC / HDR Gain Map Export",
      synopsis = bind('gm_mode'),

      f:row {
        f:static_text { title = "Mode:", alignment = 'right' },
        f:popup_menu {
          items = {
            { title = 'ISO Gain Map (Adaptive HDR)', value = 'iso' },
            { title = 'Apple Gain Map (CIFilter)',   value = 'apple_cif' },
            { title = 'Apple Gain Map (from ISO)',   value = 'apple_iso' },
            { title = 'SDR only',                    value = 'sdr' },
            { title = 'PQ HEIC (10-bit)',            value = 'pq' },
            { title = 'HLG HEIC (10-bit)',           value = 'hlg' },
          },
          value = bind('gm_mode'),
        },
      },

      f:row {
        f:static_text { title = "Image Quality:", alignment = 'right' },
        f:slider {
          value = bind 'imageQuality',
          min = 20, max = 100, fill_horizontal = 1,
          tooltip = "JPEG/HEIC base quality (20–100)",
        },
        f:edit_field { value = bind 'imageQuality', width_in_chars = 3, tooltip = "Enter image quality (20–100)" },
      },

      f:row {
        f:static_text { title = "SDR Tone-map Ratio:", alignment = 'right' },
        f:slider {
          value = bind 'sdrRatio',
          min = 0.0, max = 1.0, precision = 2, fill_horizontal = 1,
          tooltip = "0.00 = no SDR attenuation, 1.00 = strong SDR tone-map",
        },
        f:edit_field {
          value = decimalBinding('sdrRatio', 2, 0.0, 1.0),
          width_in_chars = 5, precision = 2,
        },
      },

      -- New: Gain-map size (×) instead of ratio
      f:row {
        f:static_text { title = "Gain-map size (×):", alignment = 'right' },
        f:slider {
          value = bind 'uiGainMapSize',
          min = 0.50, max = 1.00, precision = 2, fill_horizontal = 1,
          enabled = appleModeEnabledBinding(),
          tooltip = "1.00× = full size gain-map, 0.50× = half width/height",
        },
        f:edit_field {
          value = decimalBinding('uiGainMapSize', 2, 0.50, 1.00),
          width_in_chars = 5, precision = 2,
          enabled = appleModeEnabledBinding(),
        },
        f:static_text { title = " (Apple modes only)" },
      },

      f:row {
        f:static_text { title = "Color Space:", alignment = 'right' },
        f:popup_menu {
          items = {
            { title = 'sRGB / Rec.709', value = 'srgb' },
            { title = 'Display-P3',     value = 'p3' },
            { title = 'Rec.2020',       value = 'rec2020' },
          },
          value = bind('colorSpace'),
        },

        f:static_text { title = "Bit Depth:", alignment = 'right' },
        f:popup_menu {
          items = { { title = '8-bit', value = 8 }, { title = '10-bit', value = 10 } },
          value = bind('bitDepth'),
          enabled = bitDepthEnabledBinding(),
        },
      },

      f:row {
        f:static_text { title = "Container:", alignment = 'right' },
        f:popup_menu {
          items = { { title = 'HEIC', value = 'heic' }, { title = 'JPEG', value = 'jpeg' } },
          value = bind('container'),
        },
        f:static_text { title = "Filename suffix:", alignment = 'right' },
        f:edit_field { value = bind 'fileSuffix', width_in_chars = 16 },
      },
    },
  }
end

-- =========================
-- Processing
-- =========================
exportServiceProvider.processRenderedPhotos = function(functionContext, exportContext)
  local exportSession = exportContext.exportSession
  local nPhotos = exportSession:countRenditions()
  local progress = LrProgressScope({ title = 'Exporting (Gain Map HDR)', functionContext = functionContext })

  local props          = exportContext.propertyTable
  local imageQuality   = clampQuality(props.imageQuality)
  local gm_mode        = props.gm_mode or 'apple_cif'
  local sdrRatio       = clamp(tonumber(props.sdrRatio) or 0.20, 0.0, 1.0)
  local colorSpace     = props.colorSpace or 'p3'
  local bitDepth       = tonumber(props.bitDepth) or 10
  local container      = props.container or 'heic'
  local fileSuffix     = props.fileSuffix or ''

  -- Enforce 10-bit for PQ/HLG
  if gm_mode == 'pq' or gm_mode == 'hlg' then bitDepth = 10 end

  -- Coerce JPEG to 8-bit
  if container == 'jpeg' and bitDepth ~= 8 then
    LrDialogs.message(
      "JPEG is 8-bit",
      "Switching bit depth to 8-bit because JPEG does not support 10-bit.",
      "info"
    )
    bitDepth = 8
  end

  -- Convert UI size (×) to wrapper ratio (-H): ratio = 1 / size
  local uiSize = tonumber(props.uiGainMapSize)
  if not uiSize then
    -- derive from legacy gainMapScale if needed
    local legacyRatio = tonumber(props.gainMapScale) or 1.50
    uiSize = 1.0 / legacyRatio
  end
  uiSize = clamp(uiSize, 0.50, 1.00)
  local gainMapRatio = 1.0 / uiSize
  gainMapRatio = clamp(gainMapRatio, 1.00, 2.00)
  gainMapRatio = math.floor(gainMapRatio * 100 + 0.5) / 100 -- 2 decimals

  local wrapper = resolveWrapper()
  if not wrapper then
    LrDialogs.showError("Could not find wrapper in plugin/bin. Expected 'lrgainmap' or 'ghdr'.")
    return
  end

  local failures = 0

  for i, rendition in exportSession:renditions() do
    progress:setPortionComplete(i - 1, nPhotos)

    local ok, pathOrMessage = rendition:waitForRender()
    if ok then
      local srcPath = pathOrMessage
      local destFolder = rendition.destinationPath and LrPathUtils.parent(rendition.destinationPath)
                        or LrPathUtils.parent(srcPath)
      if not destFolder or LrFileUtils.exists(destFolder) ~= 'directory' then
        destFolder = LrPathUtils.parent(srcPath)
      end

      -- CLI expects: wrapper <input> <outputFolder> -q <0.20..1.00> ...
      local args = {
        q(wrapper),
        q(srcPath),
        q(destFolder),
        "-q", string.format("%.2f", clamp(imageQuality / 100, 0.20, 1.00)),
      }

      -- Mode switches
      if gm_mode == 'apple_cif' then
        table.insert(args, "-g")
      elseif gm_mode == 'apple_iso' then
        table.insert(args, "-a")
      elseif gm_mode == 'sdr' then
        table.insert(args, "-s")
      elseif gm_mode == 'pq' then
        table.insert(args, "-p")
      elseif gm_mode == 'hlg' then
        table.insert(args, "-h")
      elseif gm_mode == 'iso' then
        -- ISO gain map default path (no extra flag if wrapper uses iso by default)
      end

      -- Common params
      table.insert(args, "-r"); table.insert(args, string.format("%.3f", sdrRatio))
      if gm_mode == 'apple_cif' or gm_mode == 'apple_iso' then
        table.insert(args, "-H"); table.insert(args, string.format("%.2f", gainMapRatio)) -- ratio = 1/size
      end
      table.insert(args, "-c"); table.insert(args, colorSpace)
      table.insert(args, "-d"); table.insert(args, tostring(bitDepth))
      if container == 'jpeg' then table.insert(args, "-j") end
      if fileSuffix ~= ''      then table.insert(args, "-t"); table.insert(args, fileSuffix) end

      local cmd = table.concat(args, " ")
      local rc  = LrTasks.execute(cmd)

      if rc ~= 0 then
        failures = failures + 1
        LrDialogs.showError("Gain Map export failed (exit " .. tostring(rc) .. ")\n\nCommand:\n" .. cmd)
      else
        -- Remove the intermediate rendered file from Lightroom if wrapper succeeded
        if LrFileUtils.exists(srcPath) == 'file' then
          LrFileUtils.delete(srcPath)
        end
      end
    else
      failures = failures + 1
      LrDialogs.showError("Error rendering photo: " .. tostring(pathOrMessage))
    end

    progress:setPortionComplete(i, nPhotos)
    if progress:isCanceled() then break end
  end

  progress:done()

  if failures > 0 then
    LrDialogs.message("Export completed with errors", tostring(failures) .. " rendition(s) failed.", "warning")
  end
end

return exportServiceProvider
