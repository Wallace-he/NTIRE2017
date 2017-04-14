local paths = require 'paths'
local transform = require 'data/transforms'

local M = {}
local div2k = torch.class('sr.div2k', M)

function div2k:__init(opt, split)
    self.opt = opt
    self.split = split

    --self.size = 801
    --self.offset = self.size - self.opt.numVal
    self.size = 800
    self.offset = 790 -- offset + 1 ~ offset + numVal images are used to validate the training
    self.numVal = opt.numVal
    self.scale = self.opt.scale
    self.dataSize = self.opt.dataSize

    --Absolute path of the dataset
    local apath = nil
    self.ext = nil

    if opt.datatype == 'png' then
        apath = paths.concat(opt.datadir, 'DIV2K')
        self.ext = '.png'
    elseif opt.datatype == 't7' or opt.datatype == 't7pack' then
        apath = paths.concat(opt.datadir, 'DIV2K_decoded')
        self.ext = '.t7'
    else
        error('unknown -datatype (png | t7(default) | t7pack)')
    end


    local tHR = 'DIV2K_train_HR'
    local tLR = 'DIV2K_train_LR_'

    self.dirTar = paths.concat(apath, tHR)
    self.dirInp = {}

    for i = 1, #self.scale do
        table.insert(self.dirInp, paths.concat(apath, tLR .. opt.degrade, 'X' .. self.scale[i]))
        self.dirInp[i] = opt.dataSize == 'small' and self.dirInp[i] or self.dirInp[i]
        self.dirInp[i] = opt.netType ~= 'recurVDSR' and self.dirInp[i] or self.dirInp[i] .. '_SRresOutput'
    end

    --Load single .t7 files that contains all dataset
    if opt.datatype == 't7pack' then
        print('\tLoading t7pack:')
        if split == 'train' then
            --Here, we will split the validation sets and save them as *v.t7 file
            self.t7Tar = torch.load(paths.concat(self.dirTar, 'pack.t7'))
            local valImgs = {table.unpack(self.t7Tar, self.offset + 1, self.offset + self.numVal)}
            torch.save(paths.concat(self.dirTar, 'pack_v.t7'), valImgs)
            print('\tTrain set: ' .. self.dirTar .. '/pack.t7 loaded')

            self.t7Inp = {}
            for i = 1, #self.dirInp do
                if self.scale[i] ~= 1 then
                    table.insert(self.t7Inp, torch.load(paths.concat(self.dirInp[i], 'pack.t7')))
                    local valImgs = {table.unpack(self.t7Inp[i], self.offset + 1, self.offset + self.numVal)}
                    torch.save(paths.concat(self.dirInp[i], 'pack_v.t7'), valImgs)
                    print('\tTrain set: ' .. self.dirInp[i] .. '/pack.t7 loaded')
                else
                    table.insert(self.t7Inp, self.t7Tar)
                end
            end
        elseif split == 'val' then
            self.t7Tar = torch.load(paths.concat(self.dirTar, 'pack_v.t7'))
            print('\tValidation set: ' .. self.dirTar .. '/pack_v.t7 loaded')
            self.t7Inp = {}
            for i = 1, #self.dirInp do
                if self.scale[i] ~= 1 then
                    table.insert(self.t7Inp, torch.load(paths.concat(self.dirInp[i], 'pack_v.t7')))
                    print('\tValidation set: ' .. self.dirInp[i] .. '/pack_v.t7 loaded')
                else
                    table.insert(self.t7Inp, self.t7Tar)
                end
            end
        end
    end

    collectgarbage()
    collectgarbage()
end

function div2k:get(idx, scaleIdx)
    local idx = idx
    local scale = self.scale[scaleIdx]
    local dataSize = self.dataSize

    if self.split == 'train' then
        if idx > self.offset then
            idx = idx + self.numVal
        end
    elseif self.split == 'val' then
        if self.opt.datatype ~= 't7pack' then
            idx = idx + self.offset
        end
    end

    local input, target
    if self.opt.datatype == 't7pack' then
        input = self.t7Inp[scaleIdx][idx]
        target = self.t7Tar[idx]
    elseif self.opt.datatype == 't7' then
        local inputName, targetName = self:getFileName(idx, scale)
        input = torch.load(paths.concat(self.dirInp[scaleIdx], inputName))
        target = torch.load(paths.concat(self.dirTar, targetName))
    elseif self.opt.datatype == 'png' then
        local inputName, targetName = self:getFileName(idx, scale)
        input = image.load(paths.concat(self.dirInp[scaleIdx], inputName), self.opt.nChannel, 'float')
        target = image.load(paths.concat(self.dirTar, targetName), self.opt.nChannel, 'float')
    end

    local _, h, w = unpack(target:size():totable())
    local hInput, wInput = math.floor(h / scale), math.floor(w / scale)
    local hTarget, wTarget = scale * hInput, scale * wInput
    target = target[{{}, {1, hTarget}, {1, wTarget}}]
    
    local patchSize = self.opt.patchSize
    local targetPatch = self.opt.multiPatch and (patchSize * scale) or patchSize
    local inputPatch = targetPatch / scale

    if (wTarget < targetPatch) or (hTarget < targetPatch) then
        return nil
    end

    --Generate patches for training
    if self.split == 'train' then
        local ix = torch.random(1, wInput - inputPatch + 1)
        local iy = torch.random(1, hInput - inputPatch + 1)
        local tx = scale * (ix - 1) + 1
        local ty = scale * (iy - 1) + 1
        input = input[{{}, {iy, iy + inputPatch - 1}, {ix, ix + inputPatch - 1}}]
        target = target[{{}, {ty, ty + targetPatch - 1}, {tx, tx + targetPatch - 1}}]
    end

    if self.opt.datatype == 'png' then
        input:mul(self.opt.mulImg)
        target:mul(self.opt.mulImg)
    else
        input = input:float():mul(self.opt.mulImg / 255)
        target = target:float():mul(self.opt.mulImg / 255)
    end

    --Reject the patch that has small size of spatial gradient
    if self.split == 'train' and self.opt.rejection ~= -1 then
        local grT, grP = nil, nil
        if self.opt.rejectionType == 'input' then
            grT, grP = input, inputPatch
        elseif self.opt.rejectionType == 'target' then
            grT, grP = target, targetPatch
        end

        local dx = grT[{{}, {1, grP - 1}, {1, grP - 1}}] - grT[{{}, {1, grP - 1}, {2, grP}}]
        local dy = grT[{{}, {1, grP - 1}, {1, grP - 1}}] - grT[{{}, {2, grP}, {1, grP - 1}}]
        local dsum = dx:pow(2) + dy:pow(2)
        local dsqrt = dsum:sqrt()
        local gradValue = dsqrt:view(-1):mean()
        
        if self.gradStatistics == nil then
            self.gradSamples = 10000
            self.gsTable = {}
            self.gradStatistics = {}
            for i = 1, #self.scale do
                table.insert(self.gsTable, {})
                table.insert(self.gradStatistics, -1)
            end
            print('Caculating median of gradient for ' .. self.gradSamples .. ' samples...')
            return nil
        end
        
        if #self.gsTable[scaleIdx] < self.gradSamples then
            table.insert(self.gsTable[scaleIdx], gradValue)
            return nil
        else
            if self.gradStatistics[scaleIdx] == -1 then
                local threshold = math.floor(self.gradSamples * self.opt.rejection / 100)
                table.sort(self.gsTable[scaleIdx])
                self.gradStatistics[scaleIdx] = self.gsTable[scaleIdx][threshold]
                print('Gradient threshold for scale ' .. self.scale[scaleIdx] .. ': ' .. self.gradStatistics[scaleIdx])
                return nil
            else
                if gradValue <= self.gradStatistics[scaleIdx] then
                    print('reject!')
                    return nil
                else
                    print('accept!')
                end
            end
        end
    end

    return {
        input = input,
        target = target
    }
end

function div2k:__size()
    if self.split == 'train' then
        return self.size - self.numVal
    elseif self.split == 'val' then
        return self.numVal
    end
end

function div2k:augment()
    if (self.split == 'train') and (self.opt.degrade == 'bicubic') then
        local transforms = {}
        if self.opt.colorAug then
            table.insert(transforms,
                transform.ColorJitter({
                    brightness = 0.1,
                    contrast = 0.1,
                    saturation = 0.1
                })
            )
        end
        -- We don't need vertical flip, since hflip + rotation covers it
        table.insert(transforms, transform.HorizontalFlip())
        table.insert(transforms, transform.Rotation())

        return transform.Compose(transforms)
    else
        return function(sample) return sample end
    end
end

function div2k:getFileName(idx, scale)
    --filename format: ????x?.png
    local fileName = idx
    local digit = idx
    while (digit < 1000) do
        fileName = '0' .. fileName
        digit = digit * 10
    end

    local targetName = fileName .. self.ext
    local inputName = nil
    if scale == 1 then
        inputName = targetName
    else
        if self.opt.netType ~= 'recurVDSR' then
            inputName = fileName .. 'x' .. scale .. self.ext
        else
            inputName = 'SRres' .. fileName .. 'x' .. scale .. self.ext
        end
    end

    return inputName, targetName
end

return M.div2k
