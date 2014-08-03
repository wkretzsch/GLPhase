/* @(#)geneticMap.hpp
 */

#ifndef _GENETICMAP_HPP
#define _GENETICMAP_HPP 1

static_assert(__cplusplus > 199711L, "Program requires C++11 capable compiler");

#include <vector>
#include <algorithm>
#include <string>
#include <exception>
#include <utility>
#include "utils.hpp"
#include <boost/algorithm/string.hpp>

namespace GeneticMapHelper {

class GenomPosOutsideMap : public std::runtime_error {
private:
  unsigned genomPos;

public:
  GenomPosOutsideMap(unsigned pos)
      : std::runtime_error("Genomic location " + std::to_string(pos) +
                           " is not on genetic map"),
        genomPos(pos) {}
  unsigned GetGenomPos() const {
    return genomPos;
  };
};
}

class GeneticMap {

private:
  std::vector<std::pair<unsigned, double> > m_sortedMap;

public:
  GeneticMap(std::string &fileName);
  double GeneticLocation(unsigned genomLoc);
  double GeneticDistance(unsigned first, unsigned second);
};

#endif /* _GENETICMAP_HPP */
