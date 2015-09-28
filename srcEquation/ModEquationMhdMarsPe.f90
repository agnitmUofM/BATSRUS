!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModVarIndexes

  use ModSingleFluid
  use ModExtraVariables, &
       Redefine => Pe_

  implicit none

  save

  ! This equation module contains the MHD equations with species for Mars
  character (len=*), parameter :: NameEquation='Mars MHD with electron pressure'

  ! Number of variables without energy:
  integer, parameter :: nVar = 13

  ! Named indexes for State_VGB and other variables
  ! These indexes should go subsequently, from 1 to nVar+1.
  ! The energy is handled as an extra variable, so that we can use
  ! both conservative and non-conservative scheme and switch between them.
  integer, parameter :: &
       Rho_     = 1,    &
       RhoHp_   = 2,    &
       RhoO2p_  = 3,    &
       RhoOp_   = 4,    &
       RhoCO2p_ = 5,    &
       RhoUx_   = 6,    &
       RhoUy_   = 7,    &
       RhoUz_   = 8,    &
       Bx_      = 9,    &
       By_      =10,    &
       Bz_      =11,    &
       Pe_      =12,    &
       p_       = nVar, &
       Energy_  = nVar+1

  ! This allows to calculate RhoUx_ as rhoU_+x_ and so on.
  integer, parameter :: RhoU_ = RhoUx_-1, B_ = Bx_-1

  ! These arrays are useful for multifluid
  integer, parameter :: iRho_I(nFluid)   = (/Rho_/)
  integer, parameter :: iRhoUx_I(nFluid) = (/RhoUx_/)
  integer, parameter :: iRhoUy_I(nFluid) = (/RhoUy_/)
  integer, parameter :: iRhoUz_I(nFluid) = (/RhoUz_/)
  integer, parameter :: iP_I(nFluid)     = (/p_/)

  ! The default values for the state variables:
  ! Variables which are physically positive should be set to 1,
  ! variables that can be positive or negative should be set to 0:
  real, parameter :: DefaultState_V(nVar+1) = (/ & 
       1.0, & ! Rho_
       1.0, & ! RhoHp_
       1.0, & ! RhoO2p_
       1.0, & ! RhoOp_
       1.0, & ! RhoCO2p_
       0.0, & ! RhoUx_
       0.0, & ! RhoUy_
       0.0, & ! RhoUz_
       0.0, & ! Bx_
       0.0, & ! By_
       0.0, & ! Bz_
       1.0, & ! Pe_
       1.0, & ! p_
       1.0 /) ! Energy_

  ! The names of the variables used in i/o
  character(len=4) :: NameVar_V(nVar+1) = (/ &
       'Rho ', & ! Rho_
       'Hp  ', & ! RhoHp_
       'O2p ', & ! RhoO2p_
       'Op  ', & ! RhoOp_
       'CO2p', & ! RhoCO2p_
       'Mx  ', & ! RhoUx_
       'My  ', & ! RhoUy_
       'Mz  ', & ! RhoUz_
       'Bx  ', & ! Bx_
       'By  ', & ! By_
       'Bz  ', & ! Bz_
       'Pe  ', & ! Pe_
       'p   ', & ! p_
       'e   ' /) ! Energy_

  ! The space separated list of nVar conservative variables for plotting
  character(len=*), parameter :: NameConservativeVar = &
       'rho Hp O2p Op CO2p mx my mz bx by bz pe e'

  ! The space separated list of nVar primitive variables for plotting
  character(len=*), parameter :: NamePrimitiveVar = &
       'rho Hp O2p Op CO2p ux uy uz bx by bz pe p'

  ! The space separated list of nVar primitive variables for TECplot output
  character(len=*), parameter :: NamePrimitiveVarTec = &
       '"`r", "H+", "O_2+", "O+", "CO_2+", "U_x", "U_y", "U_z", "B_x", "B_y", "B_z","p_e", "p"'

  ! Names of the user units for IDL and TECPlot output
  character(len=20) :: &
       NameUnitUserIdl_V(nVar+1) = '', NameUnitUserTec_V(nVar+1) = ''

  ! The user defined units for the variables
  real :: UnitUser_V(nVar+1) = 1.0

  ! Primitive variable names
  integer, parameter :: U_ = RhoU_, Ux_ = RhoUx_, Uy_ = RhoUy_, Uz_ = RhoUz_

  ! Scalars to be advected.
  integer, parameter :: ScalarFirst_ = RhoHp_, ScalarLast_ = RhoCO2p_

  ! Species
  logical, parameter :: UseMultiSpecies = .true.
  integer, parameter :: SpeciesFirst_   = ScalarFirst_
  integer, parameter :: SpeciesLast_    = ScalarLast_

  ! Molecular mass of species H, O2, O, CO2 in AMU:
  real:: MassSpecies_V(SpeciesFirst_:SpeciesLast_) = (/1.0, 32.0, 16.0, 44.0/)

contains

  subroutine init_mod_equation

    call init_mhd_variables

  end subroutine init_mod_equation

end module ModVarIndexes