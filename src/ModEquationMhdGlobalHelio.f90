module ModVarIndexes

  implicit none

  save

  ! This equation module contains the MHD equations with species for Mars
  character (len=*), parameter :: NameEquation='Mars MHD'

  ! The variables numbered from 1 to nVar are:
  !
  ! 1. defined in set_ICs.
  ! 2. prolonged and restricted in AMR
  ! 3. saved into the restart file
  ! 4. sent and recieved in the exchange message
  ! 5. filled in the outer ghostcells by the program set_outer_BCs
  ! 5. integrated by subroutine integrate_all for saving to logfile
  ! 6. should be updated by advance_*

  integer, parameter :: nVar = 12

  ! Named indexes for State_VGB and other variables
  ! These indexes should go subsequently, from 1 to nVar+1.
  ! The energy is handled as an extra variable, so that we can use
  ! both conservative and non-conservative scheme and switch between them.
  integer, parameter :: &
       Rho_     = 1,    &
       Hp_      = 2,    &
       O2p_     = 3,    &
       Op_      = 4,    &
       CO2p_    = 5,    &
       RhoUx_   = 6,    &
       RhoUy_   = 7,    &
       RhoUz_   = 8,    &
       Bx_      = 9,    &
       By_      =10,    &
       Bz_      =11,    &
       p_       = nVar, &
       Energy_  = nVar+1

  ! This allows to calculate RhoUx_ as rhoU_+x_ and so on.
  integer, parameter :: RhoU_ = RhoUx_-1, B_ = Bx_-1

  ! The default values for the state variables:
  ! Variables which are physically positive should be set to 1,
  ! variables that can be positive or negative should be set to 0:
  real, parameter :: DefaultState_V(nVar+1) = (/ & 
       1.0, & ! Rho_
       1.0, & ! Hp_
       1.0, & ! O2p_
       1.0, & ! Op_
       1.0, & ! CO2p_
       0.0, & ! RhoUx_
       0.0, & ! RhoUy_
       0.0, & ! RhoUz_
       0.0, & ! Bx_
       0.0, & ! By_
       0.0, & ! Bz_
       1.0, & ! p_
       1.0 /) ! Energy_

  ! The names of the variables used in i/o
  character(len=*), parameter :: NameVar_V(nVar+1) = (/ &
       'Rho  ', & ! Rho_
       'Hp   ', & ! RhoHp_
       'O2p  ', & ! RhoO2p_
       'Op   ', & ! RhoOp_
       'CO2p ', & ! RhoCO2p_
       'RhoUx', & ! RhoUx_
       'RhoUy', & ! RhoUy_
       'RhoUz', & ! RhoUz_
       'Bx   ', & ! Bx_
       'By   ', & ! By_
       'Bz   ', & ! Bz_
       'p    ', & ! p_
       'e    ' /) ! Energy_

  ! The space separated list of nVar conservative variables for plotting
  character(len=*), parameter :: NameConservativeVar = &
       'rho Hp O2p Op CO2p mx my mz bx by bz e'

  ! The space separated list of nVar primitive variables for plotting
  character(len=*), parameter :: NamePrimitiveVar = &
       'rho Hp O2p Op CO2p ux uy uz bx by bz p'

  ! The space separated list of nVar primitive variables for TECplot output
  character(len=*), parameter :: NamePrimitiveVarTec = &
       '"`r", "H+", "O_2+", "O+", "CO_2+", "U_x", "U_y", "U_z", "B_x", "B_y", "B_z", "p"'

  ! Names of the user units for IDL and TECPlot output
  character(len=20) :: &
       NameUnitUserIdl_V(nVar+1) = '', NameUnitUserTec_V(nVar+1) = ''

  ! The user defined units for the variables
  real :: UnitUser_V(nVar+1) = 1.0

  ! Named indexes for corrected fluxes
  integer, parameter :: Vdt_ = nVar+1
  integer, parameter :: BnL_ = nVar+2
  integer, parameter :: BnR_ = nVar+3
  integer, parameter :: nCorrectedFaceValues = BnR_

  ! Primitive variable names
  integer, parameter :: U_ = RhoU_, Ux_ = RhoUx_, Uy_ = RhoUy_, Uz_ = RhoUz_

  ! Scalars to be advected.
  integer, parameter :: ScalarFirst_ = Hp_, ScalarLast_ = CO2p_

contains

  subroutine init_mod_equation

    call init_mhd_variables

  end subroutine init_mod_equation

end module ModVarIndexes
