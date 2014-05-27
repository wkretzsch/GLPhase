#include "hmmLike.hcu"

using namespace std;

namespace HMMLikeCUDA {

// basically avoid singularity or floating point error
__constant__ float norm;
__constant__ float transitionMat[NUMSITES * 3];
__constant__ float mutationMat[4 * 4];

__device__ void UnpackGLsWithCodeBook(uint32_t GLcodes, float (&GLs)[3],
                                      const float *__restrict__ codeBook,
                                      unsigned char glIdx) {

  // create mask that gives me just the rightmost n bits
  const uint32_t mask = (1 << BITSPERCODE) - 1;

  // push the code of interest to the right
  uint32_t GLcode =
      GLcodes >> UINT32T_SIZE - (BITSPERCODE * glIdx) - BITSPERCODE;

  // keep onlyt the code of interest
  GLcode &= mask;
  GLs[0] = codeBook[2 * GLcode];
  GLs[1] = codeBook[2 * GLcode + 1];
  GLs[2] = max(1 - GLs[0] - GLs[1], 0.0f);
}

/* deprecated
__device__ void UnpackGLs(unsigned char GLset, float (&GLs)[3]) {

GLs[0] = (((GLset >> 4) & 15) + 0.5f) / 16;
GLs[1] = ((GLset & 15) + 0.5f) / 16;
GLs[2] = max(1 - GLs[0] - GLs[1], 0.0f);
}
*/

__device__ void FillEmit(const float (&GLs)[3], float (&emit)[4]) {

  for (unsigned i = 0; i < 4; ++i)
    emit[i] = mutationMat[i] * GLs[0] + mutationMat[i + 4 * 1] * GLs[1] +
              mutationMat[i + 4 * 2] * GLs[1] + mutationMat[i + 4 * 3] * GLs[2];
}

// test if bit I is 1
__device__ uint64_t test(const uint64_t *P, unsigned I) {
  return (P[I >> WORDSHIFT] >> (I & WORDMOD)) & static_cast<uint64_t>(1);
}

// this should add up to around 88 registers
// 1 + 4 + 2 + 1 + 2 = 10 registers, maybe optimized away by compiler?
__device__ float hmmLike(unsigned idx, const unsigned (&hapIdxs)[4],
                         const uint32_t *__restrict__ d_packedGLs,
                         unsigned packedGLStride,
                         const uint64_t *__restrict__ d_hapPanel,
                         const float *__restrict__ d_codeBook) {

  // pull the four haplotypes into f0, f1, m0 and m1
  // 8 registers?
  const uint64_t *f0 = &d_hapPanel[hapIdxs[0] * WN],
                 *f1 = &d_hapPanel[hapIdxs[1] * WN],
                 *m0 = &d_hapPanel[hapIdxs[2] * WN],
                 *m1 = &d_hapPanel[hapIdxs[3] * WN];

  // ##########
  // Convert packed GLs back to floats

  float GLs[3]; // 3 registers
  UnpackGLsWithCodeBook(d_packedGLs[idx], GLs, d_codeBook, 0);

  // pull out phase emission and transition probabilities
  float emit[4]; // 4 registers
  FillEmit(GLs, emit);

  float sum, score = 0; // 2 registers

  // l00 = prob of 0|0 phase, etc.
  // all set to 1/4 * emission probability
  // 4 registers
  float l00 = 0.25f * emit[(test(f0, 0) << 1) | test(m0, 0)],
        l01 = 0.25f * emit[(test(f0, 0) << 1) | test(m1, 0)];
  float l10 = 0.25f * emit[(test(f1, 0) << 1) | test(m0, 0)],
        l11 = 0.25f * emit[(test(f1, 0) << 1) | test(m1, 0)];

  //  1 register
  for (uint32_t site = 1; site < NUMSITES; ++site) {
    // move to next site for e and t

    // #########
    // Convert packed GLs back to floats

    const unsigned char numGLsPerUint32 = UINT32T_SIZE / BITSPERCODE;

    // poor man's modulo: site % numGLsPerUint32 = (site & (numGLsPerUint32 -
    // 1))
    // Works only if numGLsPerUint32 is a factor of 2
    //
    // poor man's log2(n) =  __ffs(n) - 1
    // only works if n is a factor of 2
    const unsigned packedGLIdx =
        idx + (site >> (__ffs(numGLsPerUint32) - 1)) * packedGLStride;
    const unsigned char withinUINTCodeNum = site & (numGLsPerUint32 - 1);
    UnpackGLsWithCodeBook(d_packedGLs[packedGLIdx], GLs, d_codeBook,
                          withinUINTCodeNum);

    // fill emit with next site's emission matrix
    FillEmit(GLs, emit);

    // bxx = backward probabilities of being in phase xx
    // 4 registers
    const float b00 = l00 * transitionMat[site * 3] +
                      (l01 + l10) * transitionMat[site * 3 + 1] +
                      l11 * transitionMat[site * 3 + 2];
    const float b01 = l01 * transitionMat[site * 3] +
                      (l00 + l11) * transitionMat[site * 3 + 1] +
                      l10 * transitionMat[site * 3 + 2];
    const float b10 = l10 * transitionMat[site * 3] +
                      (l00 + l11) * transitionMat[site * 3 + 1] +
                      l01 * transitionMat[site * 3 + 2];
    const float b11 = l11 * transitionMat[site * 3] +
                      (l01 + l10) * transitionMat[site * 3 + 1] +
                      l00 * transitionMat[site * 3 + 2];

    l00 = b00 * emit[(test(f0, site) << 1) | test(m0, site)];
    l01 = b01 * emit[(test(f0, site) << 1) | test(m1, site)];
    l10 = b10 * emit[(test(f1, site) << 1) | test(m0, site)];
    l11 = b11 * emit[(test(f1, site) << 1) | test(m1, site)];

    // rescale probabilities if they become too small
    // hopefully this does not happen too often...
    if ((sum = l00 + l01 + l10 + l11) < norm) {
      sum = 1.0f / sum;
      score -= __logf(sum); // add sum to score
      l00 *= sum;
      l01 *= sum;
      l10 *= sum;
      l11 *= sum;
    }
  }

  return score + __logf(l00 + l01 + l10 + l11);
};

// definition of HMM kernel
__global__ void findHapSet(const uint32_t *__restrict__ d_packedGLs,
                           const uint64_t *__restrict__ d_hapPanel,
                           const unsigned *__restrict__ d_hapIdxs,
                           const unsigned *__restrict__ d_extraPropHaps,
                           unsigned *d_chosenHapIdxs, unsigned numSamples,
                           unsigned numCycles, curandStateXORWOW_t *globalState,
                           const float *__restrict__ d_codeBook
#ifdef DEBUG
                           ,
                           float *d_likes
#endif
                           ) {

  const float S = 1;
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < numSamples) {

    curandStateXORWOW_t localState = globalState[idx];

    unsigned hapIdxs[4];
    for (int i = 0; i < 4; ++i)
      hapIdxs[i] = d_hapIdxs[idx + numSamples * i];

    // define emission matrix
    float curr =
        hmmLike(idx, hapIdxs, d_packedGLs, numSamples, d_hapPanel, d_codeBook);

    // pick a random haplotype to replace with another one from all
    // haplotypes.  calculate the new probability of the model given
    // those haplotypes.
    // accept new set if probability has increased.
    // otherwise, accept with penalized probability

    for (int cycle = 0; cycle < numCycles; ++cycle) {

      // replace a sample
      unsigned replaceHapNum = curand(&localState) & 3;
      unsigned origHap = hapIdxs[replaceHapNum];

      hapIdxs[replaceHapNum] = d_extraPropHaps[idx + cycle * numSamples];
      float prop = hmmLike(idx, hapIdxs, d_packedGLs, numSamples, d_hapPanel,
                           d_codeBook);

      // accept new set
      if (curand_uniform(&localState) < __expf((prop - curr) * S))
        curr = prop;
      // reject new set
      else
        hapIdxs[replaceHapNum] = origHap;

    } // last of numCycles
    for (int i = 0; i < 4; ++i)
      d_chosenHapIdxs[idx + numSamples * i] = hapIdxs[i];

    // update global state
    globalState[idx] = localState;

    // return nothing.  d_chosenHapIdxs is the return data
    return;
  }
}

// initializes random number generator states
__global__ void setup_generators(curandStateXORWOW_t *state, size_t stateSize,
                                 unsigned long seed) {

  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < stateSize)
    curand_init(seed, idx, 0, &state[idx]);
}

void CheckDevice() {

  cudaError_t err;
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Error before starting: " << cudaGetErrorString(err) << "\n";

    exit(EXIT_FAILURE);
  }

  int deviceCount = 0;

  // note your project will need to link with cuda.lib files on windows
  cout << "Querrying CUDA Device(s)...\n\n";

  err = cudaGetDeviceCount(&deviceCount);

  if (err != cudaSuccess) {
    cout << "cuDeviceGetCount returned " << err << "\n";
    cout << "Result = FAIL\n";
    exit(EXIT_FAILURE); //
  }

  cout << "Found " << deviceCount << " device(s)" << endl;

  for (int i = 0; i < deviceCount; ++i) {
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, i);
    cout << "Device number: " << i << endl;
    cout << "Name: " << prop.name << endl;
    cout << "Compute capability: " << prop.major << '.' << prop.minor << endl;

    if (prop.major < 3 || prop.major == 3 && prop.minor < 5) {
      cerr << "Compute capability >= 3.5 required" << endl;
      exit(EXIT_FAILURE);
    }

    // set device to use more L1 cache than shared mem
    cout << "\nSetting device to prefer L1 cache over shared mem\n";
    if (cudaDeviceSetCacheConfig(cudaFuncCachePreferL1) != cudaSuccess) {
      cerr << "Could not set device caching preference to L1\n";
    }

    cudaFuncCache pCacheConfig;
    if (cudaDeviceGetCacheConfig(&pCacheConfig) != cudaSuccess) {
      cerr << "Could not get device caching preference\n";
    }
    if (pCacheConfig == cudaFuncCachePreferL1)
      cout << "Device caching preference is set to prefer L1" << endl;
    else
      cout << "Device caching preference is not set to prefer L1" << endl;
  }

  // also, this looks like as good of a place as any to define some constants
  float localNorm = powf(FLT_MIN, 2.0f / 3.0f);
  err = cudaMemcpyToSymbol(norm, &localNorm, sizeof(float), 0,
                           cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    cerr << "Error copying value to symbol: " << cudaGetErrorString(err)
         << "\n";

    exit(EXIT_FAILURE);
  }

  return;
}

void CopyTranToDevice(const vector<float> &tran) {

  assert(tran.size() == NUMSITES * 3);
  // first three values of tran are never used
  for (unsigned i = 3; i < tran.size(); i += 3)
    assert(abs(tran[i] + 2 * tran[i + 1] + tran[i + 2] - 1) < 0.1);
  cudaError_t err = cudaMemcpyToSymbol(transitionMat, tran.data(),
                                       sizeof(float) * NUMSITES * 3, 0,
                                       cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    stringstream outerr(
        "Could not copy transition matrix to device with error: ");
    outerr << err;
    throw std::runtime_error(outerr.str());
  }
}

void CopyMutationMatToDevice(const float (*mutMat)[4][4]) {

  vector<float> h_mutMat(4 * 4);
  for (int i = 0; i < 4; ++i)
    for (int j = 0; j < 4; ++j)
      h_mutMat[i + 4 * j] = ((*mutMat))[i][j];

  cudaError_t err =
      cudaMemcpyToSymbol(mutationMat, h_mutMat.data(), sizeof(float) * 4 * 4, 0,
                         cudaMemcpyHostToDevice);
  if (err != cudaSuccess) {
    stringstream outerr(
        "Could not copy mutation matrix to device with error: ");
    outerr << err;
    throw std::runtime_error(outerr.str());
  }
}

thrust::device_vector<uint32_t> *gd_packedGLs = NULL;
void CopyPackedGLsToDevice(const vector<uint32_t> &packedGLs) {
  thrust::device_vector<uint32_t> fillPackedGLs(packedGLs);

  // gotta manually new the thrust vector because it'll get deleted too late
  // otherwise...
  if (!gd_packedGLs)
    gd_packedGLs = new thrust::device_vector<uint32_t>;
  gd_packedGLs->swap(fillPackedGLs);
}

thrust::device_vector<float> *gd_codeBook = NULL;
void CopyCodeBookToDevice(const vector<pair<float, float> > &codeBook) {

  thrust::host_vector<float> h_codeBook;
  h_codeBook.reserve(codeBook.size() * 2);
  for (unsigned idx = 0; idx < codeBook.size(); ++idx) {
    h_codeBook.push_back(codeBook[idx].first);
    h_codeBook.push_back(codeBook[idx].second);
  }

  // gotta manually new the thrust vector because it'll get deleted too late
  // otherwise...
  if (!gd_codeBook)
    gd_codeBook = new thrust::device_vector<float>;
  *gd_codeBook = h_codeBook;
}

// copy hsum into stl vector
thrust::device_vector<uint32_t> *gd_hapSum = NULL;
void CopyHapSumToHost(thrust::host_vector<uint32_t> &h_hapSums) {
  assert(gd_hapSum);
  h_hapSums = *gd_hapSum;
  return;
}

void Cleanup() {
  if (gd_packedGLs) {
    delete gd_packedGLs;
    gd_packedGLs = NULL;
  }
  if (gd_codeBook) {
    delete gd_codeBook;
    gd_codeBook = NULL;
  }
  if (gd_devStates) {
    assert(cudaFree(gd_devStates) == cudaSuccess);
    gd_devStates = NULL;
  }
  if (gd_hapPanel) {
    delete gd_hapPanel;
    gd_hapPanel = NULL;
  }
  if (gd_newHapPanel) {
    delete gd_newHapPanel;
    gd_newHapPanel = NULL;
  }
  if (gd_hapSum) {
    delete gd_hapSum;
    gd_hapSum = NULL;
  }
}

/*
Set up numSamp random generator states
*/
curandStateXORWOW_t *gd_devStates = NULL;
void SetUpRNGs(size_t numSamples, unsigned long seed) {

  cudaError_t err = cudaSuccess;
  cudaMalloc(&gd_devStates, numSamples * sizeof(curandStateXORWOW_t));

  // set up generators
  unsigned threadsPerBlock = 128;
  unsigned blocksPerRun = (numSamples + threadsPerBlock - 1) / threadsPerBlock;

  setup_generators << <blocksPerRun, threadsPerBlock>>>
      (gd_devStates, numSamples, seed);

  // check exit status
  err = cudaGetLastError();

  if (err != cudaSuccess) {
    ostringstream errstr;
    errstr << "Failed to set up random states kernel: "
           << cudaGetErrorString(err);
    throw std::runtime_error(errstr.str());
  }
}

/*
copy haplotypes to device memory
*/
thrust::device_vector<uint64_t> *gd_hapPanel = NULL;
void CopyHapPanelToDevice(const vector<uint64_t> &hapPanel) {

  thrust::device_vector<uint64_t> fillHapPanel(hapPanel);

  // gotta manually new the thrust vector because it'll get deleted too late
  // otherwise...
  if (!gd_hapPanel)
    gd_hapPanel = new thrust::device_vector<uint64_t>;
  gd_hapPanel->swap(fillHapPanel);
}

thrust::device_vector<uint64_t> *gd_newHapPanel = NULL;
void InitializeNewHapPanel(thrust::device_vector<uint64_t> *d_hapPanel) {

  assert(d_hapPanel);
  assert(gd_newHapPanel == NULL);
  gd_newHapPanel = new thrust::device_vector<uint64_t>;
  *gd_newHapPanel = *d_hapPanel;
}

void RunHMMOnDevice(const vector<uint64_t> &hapPanel,
                    const vector<unsigned> &extraPropHaps, unsigned numSites,
                    unsigned numSamples, unsigned numCycles,
                    vector<unsigned> &hapIdxs) {
  assert(numSites == NUMSITES);
  assert(gd_packedGLs); // make sure pointer points to something
  if (gd_packedGLs->size() !=
      numSamples * numSites * BITSPERCODE / UINT32T_SIZE) {
    ostringstream err;
    err << "gd_packed GLs has wrong size: " << gd_packedGLs->size();
    throw std::runtime_error(err.str());
  }
  assert(gd_codeBook); // make sure pointer points to something
  assert(gd_codeBook->size() == 2 * (1 << BITSPERCODE));

  assert(hapPanel.size() >=
         WN * (*max_element(extraPropHaps.begin(), extraPropHaps.end()) + 1));
  assert(hapIdxs.size() == numSamples * 4);
  assert(extraPropHaps.size() == numSamples * numCycles);

#ifdef DEBUG
  // debug info
  cout << "Hap Idxs before sampling: ";
  for (int i = 0; i < hapIdxs.size(); ++i)
    cout << hapIdxs[i] << " ";
  cout << endl;
#endif

  cudaError_t err = cudaSuccess;

  CopyHapPanelToDevice(hapPanel);
  const uint64_t *d_hapPanel = thrust::raw_pointer_cast(gd_hapPanel->data());

  /*
    copy initial hap indices to device memory
  */
  thrust::device_vector<unsigned> d_hapIdxs(hapIdxs);
  const unsigned *d_hapIdxsPtr = thrust::raw_pointer_cast(d_hapIdxs.data());

  /*
    copy extra proposal haps to device memory
  */
  thrust::device_vector<unsigned> d_extraPropHaps(extraPropHaps);
  const unsigned *d_extraPropHapsPtr =
      thrust::raw_pointer_cast(d_extraPropHaps.data());

  /*
    allocate device memory for results
  */
  unsigned *d_chosenHapIdxs;
  const size_t hapIdxsSize = hapIdxs.size() * sizeof(unsigned);
  err = cudaMalloc(&d_chosenHapIdxs, hapIdxsSize);
  if (err != cudaSuccess) {
    cerr << "Failed to allocate memory for result hap idxs on device\n";
    exit(EXIT_FAILURE);
  }

#ifdef DEBUG
  /*
    allocate device memory for debugging floats
  */
  thrust::device_vector<float> d_likes(numCycles + 1);
  float *d_likePtr = thrust::raw_pointer_cast(d_likes.data());
#endif

  // determine thread and block size
  size_t threadsPerBlock = 128;
  size_t blocksPerRun = (numSamples + threadsPerBlock - 1) / threadsPerBlock;
#ifdef DEBUG
  cout << "[HMMLikeCUDA] Running with " << threadsPerBlock
       << " threads per block in " << blocksPerRun << " thread blocks\n";
#endif

  /*
    convert gd_packedGLs to raw ptr
  */
  const uint32_t *d_packedGLPtr =
      thrust::raw_pointer_cast(gd_packedGLs->data());

  const float *d_codeBook = thrust::raw_pointer_cast(gd_codeBook->data());
  /*
    run kernel
  */
  assert(gd_devStates);
  findHapSet << <blocksPerRun, threadsPerBlock>>>
      (d_packedGLPtr, d_hapPanel, d_hapIdxsPtr, d_extraPropHapsPtr,
       d_chosenHapIdxs, numSamples, numCycles, gd_devStates, d_codeBook
#ifdef DEBUG
       ,
       d_likePtr
#endif
       );
  cudaDeviceSynchronize();
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Failed to run findHapset kernel: " << cudaGetErrorString(err)
         << "\n";
    exit(EXIT_FAILURE);
  }

  /*
    copy result hap indices back to host into hapIdxs
  */
  err = cudaMemcpy(hapIdxs.data(), d_chosenHapIdxs, hapIdxsSize,
                   cudaMemcpyDeviceToHost);
  if (err != cudaSuccess) {
    cerr << "Failed to copy chosen indices to host: " << cudaGetErrorString(err)
         << "\nCode: " << err << "\n";
    exit(EXIT_FAILURE);
  }

  assert(cudaFree(d_chosenHapIdxs) == cudaSuccess);

#ifdef DEBUG
  thrust::host_vector<float> h_likes(numCycles + 1);
  h_likes = d_likes;

  // debug info
  cout << "Hap Idxs after sampling: ";
  for (int i = 0; i < hapIdxs.size(); ++i)
    cout << hapIdxs[i] << " ";
  cout << endl;

  cout << "cycle likelihoods: ";
  for (int i = 0; i < numCycles + 1; ++i)
    cout << h_likes[i] << " ";
  cout << endl;
#endif

  // return nothing as the return data is stored in hapIdxs
  return;
}

// take an individual number I, a set of four haplotypes P, and
// penalty S and update haplotypes of individual I
__global__ void hmmWork(const uint32_t *__restrict__ d_packedGLs,
                        const uint64_t *__restrict__ d_hapPanel,
                        const unsigned *__restrict__ d_hapIdxs,
                        unsigned numSamples, curandStateXORWOW_t *globalState,
                        const float *__restrict__ d_codeBook,
                        uint64_t *d_newHapPanel) {

  const float S = 1;
  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < numSamples) {

    curandStateXORWOW_t localState = globalState[idx];

    // setup the different haplotypes
    const uint64_t *f0 = &d_hapPanel[d_hapIdxs[idx] * WN],
                   *f1 = &d_hapPanel[d_hapIdxs[idx + numSamples] * WN],
                   *m0 = &d_hapPanel[d_hapIdxs[idx + numSamples * 2] * WN],
                   *m1 = &d_hapPanel[d_hapIdxs[idx + numSamples * 3] * WN];

    //	backward recursion
    float beta[NUMSITES * 4];

    // create pointers that point to last set of elements of emit, tran and beta
    float *bPtr = &beta[(NUMSITES - 1) * 4];
    float b00, b01, b10, b11;

    // initial state of backward sampler
    bPtr[0] = bPtr[1] = bPtr[2] = bPtr[3] = 1;

    float emit[4]; // 4 registers
    float GLs[3];  // 3 registers
    const unsigned char numGLsPerUint32 = UINT32T_SIZE / BITSPERCODE;

    // fill beta with the forward probabilites
    for (unsigned site = NUMSITES - 1; site; --site) {

      // poor man's modulo: site % numGLsPerUint32 = (site & (numGLsPerUint32 -
      // 1))
      // Works only if numGLsPerUint32 is a factor of 2
      //
      // poor man's log2(n) =  __ffs(n) - 1
      // only works if n is a factor of 2
      const unsigned packedGLIdx =
          idx + (site >> (__ffs(numGLsPerUint32) - 1)) * numSamples;
      const unsigned char withinUINTCodeNum = site & (numGLsPerUint32 - 1);
      UnpackGLsWithCodeBook(d_packedGLs[packedGLIdx], GLs, d_codeBook,
                            withinUINTCodeNum);

      // fill emit with next site's emission matrix
      FillEmit(GLs, emit);

      b00 = bPtr[0] * emit[(test(f0, site) << 1) | test(m0, site)];
      b01 = bPtr[1] * emit[(test(f0, site) << 1) | test(m1, site)];
      b10 = bPtr[2] * emit[(test(f1, site) << 1) | test(m0, site)];
      b11 = bPtr[3] * emit[(test(f1, site) << 1) | test(m1, site)];
      bPtr -= 4;
      bPtr[0] = b00 * transitionMat[site * 3] +
                (b01 + b10) * transitionMat[site * 3 + 1] +
                b11 * transitionMat[site * 3 + 2];
      bPtr[1] = b01 * transitionMat[site * 3] +
                (b00 + b11) * transitionMat[site * 3 + 1] +
                b10 * transitionMat[site * 3 + 2];
      bPtr[2] = b10 * transitionMat[site * 3] +
                (b00 + b11) * transitionMat[site * 3 + 1] +
                b01 * transitionMat[site * 3 + 2];
      bPtr[3] = b11 * transitionMat[site * 3] +
                (b01 + b10) * transitionMat[site * 3 + 1] +
                b00 * transitionMat[site * 3 + 2];
      float sum = 1.0f / (bPtr[0] + bPtr[1] + bPtr[2] + bPtr[3]);
      bPtr[0] *= sum;
      bPtr[1] *= sum;
      bPtr[2] *= sum;
      bPtr[3] *= sum;
    }

    //	forward sampling
    // walk through b
    uint64_t *ha = &d_newHapPanel[idx * 2 * WN], *hb = ha + WN;
    const float *tran = &transitionMat[0];
    bPtr = &beta[0];
    float l00 = 0, l01 = 0, l10 = 0, l11 = 0;

    for (unsigned site = 0; site != NUMSITES; ++site, tran += 3, bPtr += 4) {
      // unpack GLs
      const unsigned packedGLIdx =
          idx + (site >> (__ffs(numGLsPerUint32) - 1)) * numSamples;
      const unsigned char withinUINTCodeNum = site & (numGLsPerUint32 - 1);
      UnpackGLsWithCodeBook(d_packedGLs[packedGLIdx], GLs, d_codeBook,
                            withinUINTCodeNum);

      // fill emit with next site's emission matrix
      FillEmit(GLs, emit);

      const unsigned char s00 = (test(f0, site) << 1) | test(m0, site);
      const unsigned char s01 = (test(f0, site) << 1) | test(m1, site);
      const unsigned char s10 = (test(f1, site) << 1) | test(m0, site);
      const unsigned char s11 = (test(f1, site) << 1) | test(m1, site);
      if (site) {
        b00 = l00 * tran[0] + l01 * tran[1] + l10 * tran[1] + l11 * tran[2],
        b01 = l00 * tran[1] + l01 * tran[0] + l10 * tran[2] + l11 * tran[1];
        b10 = l00 * tran[1] + l01 * tran[2] + l10 * tran[0] + l11 * tran[1],
        b11 = l00 * tran[2] + l01 * tran[1] + l10 * tran[1] + l11 * tran[0];
        l00 = b00 * emit[s00];
        l01 = b01 * emit[s01];
        l10 = b10 * emit[s10];
        l11 = b11 * emit[s11];
      } else {
        l00 = 0.25f * emit[s00];
        l01 = 0.25f * emit[s01];
        l10 = 0.25f * emit[s10];
        l11 = 0.25f * emit[s11];
      }
      {
        const float sum = 1.0f / (l00 + l01 + l10 + l11);
        l00 *= sum;
        l01 *= sum;
        l10 *= sum;
        l11 *= sum;
      }

      // p00 is P(phase 0|0 | l, b)
      const float p00 = l00 * bPtr[0], p01 = l01 * bPtr[1], p10 = l10 * bPtr[2],
                  p11 = l11 * bPtr[3];

      // c00 is P(phase 0|0 | emit, l, b, GL) at site m penalized by S
      // powf effectively inflates the importance of small numbers
      // while S is < 1 (first bn/2 iterations)
      const float c00 =
          powf(GLs[0] * (p00 * mutationMat[s00] + p01 * mutationMat[s01] +
                         p10 * mutationMat[s10] + p11 * mutationMat[s11]),
               S);
      const float c01 = powf(
          GLs[1] * (p00 * mutationMat[s00 + 4] + p01 * mutationMat[s01 + 4] +
                    p10 * mutationMat[s10 + 4] + p11 * mutationMat[s11 + 4]),
          S);
      const float c10 = powf(
          GLs[1] *
              (p00 * mutationMat[s00 + 4 * 2] + p01 * mutationMat[s01 + 4 * 2] +
               p10 * mutationMat[s10 + 4 * 2] + p11 * mutationMat[s11 + 4 * 2]),
          S);
      const float c11 = powf(
          GLs[2] *
              (p00 * mutationMat[s00 + 4 * 3] + p01 * mutationMat[s01 + 4 * 3] +
               p10 * mutationMat[s10 + 4 * 3] + p11 * mutationMat[s11 + 4 * 3]),
          S);

      // randomly choose new haplotypes at this site weighted by c
      {
        const float sum = curand_uniform(&localState) * (c00 + c01 + c10 + c11);
        if (sum < c00) {
          set0(ha, site);
          set0(hb, site);
        } else if (sum < c00 + c01) {
          set0(ha, site);
          set1(hb, site);
        } else if (sum < c00 + c01 + c10) {
          set1(ha, site);
          set0(hb, site);
        } else {
          set1(ha, site);
          set1(hb, site);
        }
      }
    }
    globalState[idx] = localState;
  }
}

// keep a count of the number of 1s at each site for each haplotype
// ha will always have more or as many 1 alleles as hb
__global__ void sumHaps(const uint64_t *__restrict__ d_newHaps,
                        uint32_t *d_hapSum, unsigned numSamps) {

  int idx = blockDim.x * blockIdx.x + threadIdx.x;
  if (idx < numSamps) {

    // oa and ob are the observed haplotypes for individual idx
    const uint64_t *oa = &d_newHaps[idx * 2 * WN], *ob = oa + WN;

    // ha and hb are the running tally of individual idx's haplotypes
    uint32_t *ha = &d_hapSum[idx * 2 * NUMSITES], *hb = ha + NUMSITES;

    // cis and tra are used to match the haplotypes found with the correct sum
    // of haplotypes
    uint32_t cis = 0, tra = 0;
    for (unsigned site = 0; site < NUMSITES; ++site) {
      if (test(oa, site)) {
        cis += ha[site];
        tra += hb[site];
      }
      if (test(ob, site)) {
        cis += hb[site];
        tra += ha[site];
      }
    }
    for (unsigned site = 0; site < NUMSITES; ++site) {
      uint64_t a = test(oa, site);
      uint64_t b = test(ob, site);
      ha[site] += cis > tra ? a : b;
      hb[site] += cis > tra ? b : a;
    }
  }
}

void SolveOnDevice(const vector<unsigned> &extraPropHaps, unsigned numSites,
                   unsigned numSamples, unsigned numCycles,
                   vector<unsigned> &hapIdxs, bool updateSum) {
  cudaError_t err = cudaSuccess;

  assert(numSites == NUMSITES);
  assert(hapIdxs.size() == numSamples * 4);
  assert(extraPropHaps.size() == numSamples * numCycles);

  // hap panel must have been copied over previously
  assert(gd_hapPanel);
  assert(gd_hapPanel->size() >=
         WN * (*max_element(extraPropHaps.begin(), extraPropHaps.end()) + 1));
  // get pointer to hap panel
  const uint64_t *d_hapPanelPtr = thrust::raw_pointer_cast(gd_hapPanel->data());

  // copy initial hap indices to device memory
  thrust::device_vector<unsigned> d_hapIdxs(hapIdxs);
  const unsigned *d_hapIdxsPtr = thrust::raw_pointer_cast(d_hapIdxs.data());

  /*
   allocate chosen hap idxs on device
  */
  unsigned *d_chosenHapIdxs;
  const size_t hapIdxsSize = hapIdxs.size() * sizeof(unsigned);

  err = cudaMalloc(&d_chosenHapIdxs, hapIdxsSize);
  if (err != cudaSuccess) {
    cerr << "Failed to allocate memory for result hap idxs on device\n";
    exit(EXIT_FAILURE);
  }

  // copy extra proposal haps to device memory
  thrust::device_vector<unsigned> d_extraPropHaps(extraPropHaps);
  const unsigned *d_extraPropHapsPtr =
      thrust::raw_pointer_cast(d_extraPropHaps.data());

  // get packed gl pointer
  assert(gd_packedGLs); // make sure pointer points to something
  assert(gd_packedGLs->size() ==
         numSamples * numSites * BITSPERCODE / UINT32T_SIZE);
  const uint32_t *d_packedGLPtr =
      thrust::raw_pointer_cast(gd_packedGLs->data());

  // get codebook pointer
  assert(gd_codeBook); // make sure pointer points to something
  assert(gd_codeBook->size() == 2 * (1 << BITSPERCODE));
  const float *d_codeBookPtr = thrust::raw_pointer_cast(gd_codeBook->data());

  /*
    run kernel
  */
  // determine thread and block size
  size_t threadsPerBlock = 128;
  size_t blocksPerRun = (numSamples + threadsPerBlock - 1) / threadsPerBlock;
  cudaDeviceSynchronize();
  assert(gd_devStates);
  findHapSet << <blocksPerRun, threadsPerBlock>>>
      (d_packedGLPtr, d_hapPanelPtr, d_hapIdxsPtr, d_extraPropHapsPtr,
       d_chosenHapIdxs, numSamples, numCycles, gd_devStates, d_codeBookPtr);
  cudaDeviceSynchronize();

  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Failed to run findHapset kernel: " << cudaGetErrorString(err)
         << "\n";
    exit(EXIT_FAILURE);
  }

  /*
    now run hmm_work to get new haplotypes
  */

  //  create new hap panel if it does not point to something
  if (gd_newHapPanel == NULL)
    InitializeNewHapPanel(gd_hapPanel);
  assert(gd_newHapPanel->size() == gd_hapPanel->size());
  // get pointer to hap panel
  uint64_t *d_newHapPanelPtr = thrust::raw_pointer_cast(gd_newHapPanel->data());

  hmmWork << <blocksPerRun, threadsPerBlock>>>
      (d_packedGLPtr, d_hapPanelPtr, d_chosenHapIdxs, numSamples, gd_devStates,
       d_codeBookPtr, d_newHapPanelPtr);

  cudaDeviceSynchronize();
  err = cudaGetLastError();
  if (err != cudaSuccess) {
    cerr << "Failed to run hmmWork kernel: " << cudaGetErrorString(err) << "\n";
    exit(EXIT_FAILURE);
  }

  assert(cudaFree(d_chosenHapIdxs) == cudaSuccess);

  // exchange new and old hap panels
  swap(*gd_hapPanel, *gd_newHapPanel);

  //  update the haplotype sum if requested
  if (updateSum) {

    if (gd_hapSum == NULL) {
      gd_hapSum = new thrust::device_vector<uint32_t>;
      gd_hapSum->resize(numSites * numSamples * 2,
                        0); // one uint for every site and sample
    }

    uint32_t *d_hapSumPtr = thrust::raw_pointer_cast(gd_hapSum->data());
    sumHaps << <blocksPerRun, threadsPerBlock>>>
        (d_newHapPanelPtr, d_hapSumPtr, numSamples);

    cudaDeviceSynchronize();
    err = cudaGetLastError();
    if (err != cudaSuccess) {
      cerr << "Failed to run sumHaps kernel: " << cudaGetErrorString(err)
           << "\n";
      exit(EXIT_FAILURE);
    }
  }
  // return nothing as the return data is stored in gd_newHapPanel
  return;
}
}
