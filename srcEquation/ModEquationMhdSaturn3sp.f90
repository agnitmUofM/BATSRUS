!  Copyright (C) 2002 Regents of the University of Michigan
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModVarIndexes

  use ModSingleFluid
  use ModExtraVariables, &
       Redefine1 => SpeciesFirst_, &
       Redefine2 => SpeciesLast_,  &
       Redefine3 => MassSpecies_V

  implicit none

  save

  character (len=*), parameter :: &
       NameEquationFile = "ModEquationMhdSaturn3sp.f90"

  ! This equation module contains the standard MHD equations with
  ! three species for Saturn.  1 - solar wind protons+ionosphere,
  ! 2 - water group plasma from the rings and Enceladus,
  ! 3 - nitrogen group plasma from Titan
  character (len=*), parameter :: &
       NameEquation = &
       'Saturn MHD 3 Species (Saturn3sp), Hansen, May, 2007'

  ! Number of variables without energy:
  integer, parameter :: nVar = 11

  ! Named indexes for State_VGB and other variables
  ! These indexes should go subsequently, from 1 to nVar+1.
  ! The energy is handled as an extra variable, so that we can use
  ! both conservative and non-conservative scheme and switch between them.
  integer, parameter :: &
       Rho_    = 1,    &
       RhoH_   = 2,    &
       RhoH2O_ = 3,    &
       RhoN_   = 4,    &
       RhoUx_  = 5,    &
       RhoUy_  = 6,    &
       RhoUz_  = 7,    &
       Bx_     = 8,    &
       By_     = 9,    &
       Bz_     = 10,    &
       p_      = nVar, &
       Energy_ = nVar+1

  ! This allows to calculate RhoUx_ as rhoU_+x_ and so on.
  integer, parameter :: RhoU_ = RhoUx_-1, B_ = Bx_-1

  ! These arrays are useful for multifluid
  integer, parameter :: iRho_I(nFluid)   = [Rho_]
  integer, parameter :: iRhoUx_I(nFluid) = [RhoUx_]
  integer, parameter :: iRhoUy_I(nFluid) = [RhoUy_]
  integer, parameter :: iRhoUz_I(nFluid) = [RhoUz_]
  integer, parameter :: iP_I(nFluid)     = [p_]

  ! The default values for the state variables:
  ! Variables which are physically positive should be set to 1,
  ! variables that can be positive or negative should be set to 0:
  real, parameter :: DefaultState_V(nVar+1) = [ &
       1.0, & ! Rho_
       1.0, & ! RhoH_
       1.0, & ! RhoH2O_
       1.0, & ! RhoN_
       0.0, & ! RhoUx_
       0.0, & ! RhoUy_
       0.0, & ! RhoUz_
       0.0, & ! Bx_
       0.0, & ! By_
       0.0, & ! Bz_
       1.0, & ! p_
       1.0 ] ! Energy_

  ! The names of the variables used in i/o
  character(len=6) :: NameVar_V(nVar+1) = [ &
       'Rho   ', & ! Rho_
       'RhoH  ', & ! RhoH_
       'RhoH2O', & ! RhoH2O_
       'RhoN  ', & ! RhoN_
       'Mx    ', & ! RhoUx_
       'My    ', & ! RhoUy_
       'Mz    ', & ! RhoUz_
       'Bx    ', & ! Bx_
       'By    ', & ! By_
       'Bz    ', & ! Bz_
       'p     ', & ! p_
       'e     ' ] ! Energy_

  ! Primitive variable names
  integer, parameter :: U_ = RhoU_, Ux_ = RhoUx_, Uy_ = RhoUy_, Uz_ = RhoUz_

  ! There are three extra scalars
  integer, parameter :: ScalarFirst_ = RhoH_, ScalarLast_ = RhoN_

  ! Species
  integer, parameter :: SpeciesFirst_   = ScalarFirst_
  integer, parameter :: SpeciesLast_    = ScalarLast_

  ! Molecular mass of solarwind, H2O and N species in AMU:
  real :: MassSpecies_V(SpeciesFirst_:SpeciesLast_) = [ 1.0, 16.6, 14.0 ]

end module ModVarIndexes
!==============================================================================
