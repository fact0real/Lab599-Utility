#include "wave.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#include <stdint.h>
#include <limits.h>

// Save signal in floating point format (-1 .. +1) as a WAVE file using 16-bit signed integers.
int save_wav(const float* signal, int num_samples, int sample_rate, const char* path)
{
    if (!signal || !path || num_samples <= 0 || num_samples > INT_MAX / 2 || sample_rate <= 0)
        return -1;
    char subChunk1ID[4] = { 'f', 'm', 't', ' ' };
    uint32_t subChunk1Size = 16; // 16 for PCM
    uint16_t audioFormat = 1;    // PCM = 1
    uint16_t numChannels = 1;
    uint16_t bitsPerSample = 16;
    uint32_t sampleRate = sample_rate;
    uint16_t blockAlign = numChannels * bitsPerSample / 8;
    uint32_t byteRate = sampleRate * blockAlign;

    char subChunk2ID[4] = { 'd', 'a', 't', 'a' };
    uint32_t subChunk2Size = num_samples * blockAlign;

    char chunkID[4] = { 'R', 'I', 'F', 'F' };
    uint32_t chunkSize = 4 + (8 + subChunk1Size) + (8 + subChunk2Size);
    char format[4] = { 'W', 'A', 'V', 'E' };

    int16_t* raw_data = (int16_t*)malloc(num_samples * blockAlign);
    if (!raw_data) return -1;
    for (int i = 0; i < num_samples; i++)
    {
        float x = signal[i];
        if (x > 1.0)
            x = 1.0;
        else if (x < -1.0)
            x = -1.0;
        raw_data[i] = (int)(0.5 + (x * 32767.0));
    }

    FILE* f = fopen(path, "wb");
    if (f == NULL) {
        free(raw_data);
        return -1;
    }

    // NOTE: works only on little-endian architecture
    fwrite(chunkID, sizeof(chunkID), 1, f);
    fwrite(&chunkSize, sizeof(chunkSize), 1, f);
    fwrite(format, sizeof(format), 1, f);

    fwrite(subChunk1ID, sizeof(subChunk1ID), 1, f);
    fwrite(&subChunk1Size, sizeof(subChunk1Size), 1, f);
    fwrite(&audioFormat, sizeof(audioFormat), 1, f);
    fwrite(&numChannels, sizeof(numChannels), 1, f);
    fwrite(&sampleRate, sizeof(sampleRate), 1, f);
    fwrite(&byteRate, sizeof(byteRate), 1, f);
    fwrite(&blockAlign, sizeof(blockAlign), 1, f);
    fwrite(&bitsPerSample, sizeof(bitsPerSample), 1, f);

    fwrite(subChunk2ID, sizeof(subChunk2ID), 1, f);
    fwrite(&subChunk2Size, sizeof(subChunk2Size), 1, f);

    fwrite(raw_data, blockAlign, num_samples, f);

    int failed = ferror(f);
    if (fclose(f) != 0) failed = 1;
    free(raw_data);
    return failed ? -1 : 0;
}

static uint16_t read_le16(const uint8_t* bytes)
{
    return (uint16_t)((uint16_t)bytes[0] | ((uint16_t)bytes[1] << 8));
}

static uint32_t read_le32(const uint8_t* bytes)
{
    return (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) |
           ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
}

// Load canonical mono 16-bit PCM WAVE files into a caller-sized buffer.
int load_wav(float* signal, int* num_samples, int* sample_rate, const char* path)
{
    if (!signal || !num_samples || !sample_rate || !path || *num_samples <= 0)
        return -1;
    FILE* f = fopen(path, "rb");
    if (!f)
        return -1;
    uint8_t header[44];
    int result = -2;
    uint8_t* raw_data = NULL;
    if (fread(header, 1, sizeof(header), f) != sizeof(header))
        goto done;
    uint32_t chunk_size = read_le32(header + 4);
    uint32_t sample_rate_value = read_le32(header + 24);
    uint32_t byte_rate = read_le32(header + 28);
    uint32_t data_size = read_le32(header + 40);
    if (memcmp(header, "RIFF", 4) || memcmp(header + 8, "WAVEfmt ", 8) ||
        memcmp(header + 36, "data", 4) || read_le32(header + 16) != 16 ||
        read_le16(header + 20) != 1 || read_le16(header + 22) != 1 ||
        read_le16(header + 32) != 2 || read_le16(header + 34) != 16 ||
        sample_rate_value == 0 || sample_rate_value > INT_MAX ||
        (uint64_t)sample_rate_value * 2 != byte_rate || chunk_size < 36 ||
        data_size == 0 || (data_size & 1) || data_size > chunk_size - 36)
        goto done;
    result = -4;
    if (data_size / 2 > (uint32_t)*num_samples)
        goto done;
    result = -1;
    raw_data = malloc(data_size);
    if (!raw_data || fread(raw_data, 1, data_size, f) != data_size)
        goto done;
    int count = (int)(data_size / 2);
    for (int i = 0; i < count; i++) {
        int value = read_le16(raw_data + (size_t)i * 2);
        if (value >= 32768) value -= 65536;
        signal[i] = value / 32768.0f;
    }
    *num_samples = count;
    *sample_rate = (int)sample_rate_value;
    result = 0;
done:
    free(raw_data);
    fclose(f);
    return result;
}
