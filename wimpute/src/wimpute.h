/* @(#)wimpute.h
 */

#ifndef _WIMPUTE_H
#define _WIMPUTE_H 1
/*
  #include <string>
  #include <fstream>
  #include <iostream>
*/
#include <memory>
#include "impute.h"
#include "emcchain.h"
#include "utils.h"
#include <limits>

//require c++11
static_assert(__cplusplus > 199711L, "Program requires C++11 capable compiler");

class Wimpute : public Impute
{

private:
    ofstream m_ofsLogFileStream;
    gzFile m_gzLogFileStream;
    bool m_bLogIsGz;
    string m_sLogFile;
    unsigned m_nIteration;
    unsigned m_uCycles;
    bool m_bUsingRefHaps = false;

    // reference haplotypes
    vector<uint64_t> m_vRefHaps;
    unsigned m_uNumRefHaps = 0;

    // numerator and denominator of relationship matrix
    // numerator = number of accepted proposals
    // denominator = number of total proposals
    // first index is individual for which proposal was made
    // second index is individual from which was copied
    vector<vector< unsigned >> m_2dRelationshipMatNum;
    vector<vector< unsigned >> m_2dRelationshipMatDen;

    
    // Wimpute redefinition of hmm_like
    // so far it only adds logging
    virtual  fast hmm_like(unsigned I, unsigned *P) override;

    virtual fast solve(unsigned I, unsigned    &N, fast S, bool P) override;

    fast solve_EMC(unsigned I, unsigned    N, fast S, bool P);

    fast solve_AMH(unsigned I, unsigned    N, fast S, bool P);

public:

    bool load_refPanel( string legendFile, string hapsFile );
    
    // print out usage
    static void document(void);
    static int s_iEstimator; // see main.cpp and document for documentation
    static unsigned s_uParallelChains; // see main.cpp and document for documentation
    static unsigned s_uCycles; // see main.cpp and document for documentation
    static bool s_bIsLogging; // true if logging

    unsigned GetNumWords() { return wn; }

    // returns allele of hap number hap at sites number site
    bool TestRefHap(uint hap, uint site){ return test(&m_vRefHaps[ hap * wn], site) == 1; }
    
    // are we logging?
    bool LogOn(void) { return s_bIsLogging; }

    // set and open log file
    void SetLog( const string &sLogFile);

    void WriteToLog( const string & tInput );
    void WriteToLog( const EMCChain & rcChain, const bool bMutate );

    bool load_bin(const char *F);

    void initialize();
    
    void estimate();

    // EMC version of estimate()
    void estimate_EMC();

    // AMH version of estimate()
    void estimate_AMH();

    // Roulette Wheel Selection, returns index of chain selected
    int RWSelection( const vector <EMCChain> & rvcChains);

    unsigned RJSelection( const vector<unsigned> & vuRetMatNum, const vector<unsigned> & vuRetMatDen, unsigned I, unsigned hn, gsl_rng * rng);

};

#endif /* _WIMPUTE_H */

