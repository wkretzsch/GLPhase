/* @(#)relationshipGraph.h
 */

#ifndef _RELATIONSHIPGRAPH_H
#define _RELATIONSHIPGRAPH_H 1

#include        <gsl/gsl_rng.h>
#include        <vector>
#include        <cassert>
#include        <cmath>
#include        <iostream>
#include        "utils.h"

//require c++11
static_assert(__cplusplus > 199711L, "Program requires C++11 capable compiler");

class RelationshipGraph{

private:

    // 1 based number of rows and columns
    unsigned m_uRows;
    unsigned m_uCols;

    // need these for AMH
    bool m_bUsingRelMat = false;
    std::vector< std::vector< float > > m_2dRelationshipMatNum;
    std::vector< std::vector< float > > m_2dRelationshipMatDen;

    // need these for clustering
    bool m_bUsingCluster = false;
    std::vector< unsigned > m_uHapClusterNum;
    std::vector< std::vector < uint64_t > > m_uClusterHaps;

    // -1 = undefined
    // 0 = sample/sample graph
    // 1 = sample/haplotype graph
    // 2 = no graph - all samples are equally related
    int m_iGraphType = -1;
    bool m_bUsingHaps = false;

    // hap to column index converter
    unsigned Hap2Col(unsigned uHap);

    // column to hap index converter
    unsigned Col2Hap(unsigned uCol);

public:

    // has the class been successfully intitialized?
    // initialization happens through a call to init()
    bool m_bInitialized = false;
    
// takes sample num and haplotype num as well as graph type
// samples can be updated, while haplotypes can only be copied from
// every sample has two haplotypes
// therefore: any haplotypes that don't match a sample are reference haps

// numerator and denominator of relationship matrix
// numerator = number of accepted proposals
// denominator = number of total proposals
// first index is individual for which proposal was made
// second index is individual from which was copied

// iGraphType:
// -1 = undefined
// 0 = sample/sample graph
// 1 = sample/haplotype graph
// 2 = no graph - all samples are equally related

    RelationshipGraph(int iGraphType, unsigned uSamples, unsigned uHaplotypes) {
        init(iGraphType, uSamples, uHaplotypes);
    };

    // need to call init after construction with empty constructor;
    RelationshipGraph(){};

    void init(int iGraphType, unsigned uSamples, unsigned uHaplotypes);

    // returns a haplotype sampled using the relationship graph
    unsigned SampleHap(unsigned uInd, gsl_rng *rng);

    // returns a haplotype sampled using the relationship graph, but only from the reference haplotypes
    unsigned SampleHap(unsigned uInd, gsl_rng *rng, bool bOnlyFromRef);

    // update graph with proposal
    void UpdateGraph( unsigned * p, bool bAccepted, unsigned uInd);

    // update graph with probability dUpdateProb
    void UpdateGraph( unsigned *p, bool bAccepted, unsigned uInd, float dUpdateProb, gsl_rng *rng);

    // update graph with number fRatio instead of 1
    void UpdateGraph( unsigned *p, bool bAccepted, unsigned uInd, float fRatio);

    void Save(std::string fileName, const vector<std::string> & name);

};

#endif /* _RELATIONSHIPGRAPH_H */
