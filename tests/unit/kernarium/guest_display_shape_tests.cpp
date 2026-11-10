// SPDX-License-Identifier: GPL-2.0-or-later

#include "KernariumGuestDisplayShape.hpp"
#include "named_tests.hpp"
#include "require.hpp"

namespace {

using namespace kernarium::display_shape;
using uml::testing::require;

void statesTheCutoutAndTheCorners()
{
    require(value(59, 130, 59) == "59,130,59");
    require(value(47, 230, 54) == "47,230,54");
    /* Rounded corners with no cutout. */
    require(value(0, 0, 18) == "0,0,18");
    require(value(maximum, maximum, maximum) == "999,999,999");
    require(prefix == "androidboot.kernarium.display_shape=");
}

void statesNothingForADisplayNothingIsHiddenOf()
{
    require(!value(0, 0, 0));
}

void refusesWhatNoScreenHas()
{
    require(!value(maximum + 1, 130, 59));
    require(!value(59, maximum + 1, 59));
    require(!value(59, 130, maximum + 1));
    require(!value(59, 0, 59));
    require(!value(0, 130, 59));
}

} // namespace

int main()
{
    static constexpr uml::testing::NamedTest tests[] = {
        {"states-the-cutout-and-the-corners", statesTheCutoutAndTheCorners},
        {"states-nothing-for-a-display-nothing-is-hidden-of",
         statesNothingForADisplayNothingIsHiddenOf},
        {"refuses-what-no-screen-has", refusesWhatNoScreenHas},
    };
    return uml::testing::runNamedTests(tests);
}
