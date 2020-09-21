!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModThreadedLC
!  use ModUtilities, ONLY: norm2
  use BATL_lib,            ONLY: test_start, test_stop, iProc
  use ModTransitionRegion, ONLY:  iTableTR, TeSiMin, SqrtZ, CoulombLog, &
       HeatCondParSi, LengthPAvrSi_, UHeat_, HeatFluxLength_, &
       DHeatFluxXOverU_, LambdaSi_, DLogLambdaOverDLogT_,init_tr
  use ModFieldLineThread,  ONLY: BoundaryThreads, BoundaryThreads_B,     &
       UseTriangulation, PSi_, TeSi_, TiSi_, AMajor_, AMinor_,           &
       DoInit_, Done_, Enthalpy_, Heat_,                                 &
       jThreadMin=>jMin_, jThreadMax=>jMax_,                             &
       kThreadMin=>kMin_, kThreadMax=>kMax_
  use ModAdvance,          ONLY: UseElectronPressure, UseIdealEos
  use ModCoronalHeating,   ONLY:PoyntingFluxPerBSi, PoyntingFluxPerB,    &
       QeRatio, MaxImbalance
  use ModPhysics,        ONLY: Z => AverageIonCharge
  use ModConst,          ONLY: rSun, mSun, cBoltzmann, cAtomicMass, cGravitation
  use ModGeometry,       ONLY: Xyz_DGB
  use ModCoordTransform, ONLY: determinant, inverse_matrix
  use ModLinearAdvection, ONLY:  &
       lin_advection_source_plus, lin_advection_source_minus
  use omp_lib
  !
  !   Hydrostatic equilibrium in an isothermal corona:
  !    d(N_i*k_B*(Z*T_e +T_i) )/dr=G*M_sun*N_I*M_i*d(1/r)/dr
  ! => N_i*Te\propto exp(cGravPot/TeSi*(M_i[amu]/(1+Z))*\Delta(R_sun/r))
  !
  !
  ! The plasma properties dependent coefficient needed to evaluate the
  ! effect of gravity on the hydrostatic equilibrium
  !
  use ModFieldLineThread, ONLY:  &
       GravHydroStat != cGravPot*MassIon_I(1)/(Z + 1)
  !
  ! To espress Te  and Ti in terms of P and rho, for ideal EOS:
  !
  !
  ! Te = TeFraction*State_V(iP)/State_V(Rho_)
  ! Pe = PeFraction*State_V(iP)
  ! Ti = TiFraction*State_V(p_)/State_V(Rho_)
  !
  use ModFieldLineThread, ONLY:  &
       TeFraction, TiFraction,  iP, PeFraction
  implicit none
  SAVE
  !
  ! energy flux needed to raise the mass flux rho*u to the heliocentric
  ! distance r equals: rho*u*G*Msun*(1/R_sun -1/r)=
  !=k_B*N_i*M_i(amu)u*cGravPot*(1-R_sun/r)=
  !=P_e/T_e*cGravPot*u(M_i[amu]/Z)*(1/R_sun -1/r)
  !
  real :: GravHydroDyn ! = cGravPot*MassIon_I(1)/AverageIonCharge

  !
  ! Temperature 3D array
  !
  real,allocatable :: Te_G(:,:,:)
  !$ omp threadprivate( Te_G )
  !
  ! Arrays for 1D distributions
  !
  real,allocatable,dimension(:):: ReflCoef_I, AMajor_I, AMinor_I,            &
       TeSi_I, TeSiStart_I, PSi_I, Xi_I, Cons_I,                  &
       TiSi_I, TiSiStart_I, SpecIonHeat_I, DeltaIonEnergy_I,      &
       VaLog_I, DXi_I, ResHeating_I, ResCooling_I, DResCoolingOverDLogT_I,   &
       ResEnthalpy_I, ResHeatCond_I, ResGravity_I, SpecHeat_I, DeltaEnergy_I,&
       ExchangeRate_I, EnthalpyFlux_I, Flux_I, DissipationMinus_I,       &
       DissipationPlus_I
  !
  ! We apply ADI to solve state vector, the components of the state
  ! being temperature and log pressure.
  ! The heating at constant pressure is characterized by the
  ! specific heat at constant pressure. For pressure the barometric
  ! formula is applied
  !
  integer, parameter:: Cons_ = 1, Ti_=2, LogP_ = 3
  integer, parameter:: ConsAMajor_ = 4, ConsAMinor_ = 5
  real, allocatable, dimension(:,:):: Res_VI, DCons_VI
  real, allocatable, dimension(:,:,:) :: M_VVI, L_VVI, U_VVI

  ! Two logicals with self-explained names
  logical        :: UseAlignedVelocity = .true.
  logical        :: DoConvergenceCheck = .false.

  ! Two parameters controling the choise of the order for density and
  ! pressure: first order (LimMin=LimMax=0), second order (LimMin=LimMax=1)
  ! or limited second order as a default
  real:: LimMin = 0.0, LimMax = 1

  ! Coefficient to express dimensionless density as RhoNoDimCoef*PeSi/TeSi
  real           ::  RhoNoDimCoef

  ! Misc
  real:: TeMin, ConsMin, ConsMax, TeSiMax

  ! For transforming conservative to TeSi and back
  real, parameter:: cTwoSevenths = 2.0/7.0

  ! Gravitation potential in K
  real, parameter:: cGravPot = cGravitation*mSun*cAtomicMass/&
       (cBoltzmann*rSun)

  ! In hydrogen palsma, the electron-ion heat exchange is described by
  ! the equation as follows:
  ! dTe/dt = -(Te-Ti)/(tau_{ei})
  ! dTi/dt = +(Te-Ti)/(tau_{ei})
  ! The expression for 1/tau_{ei} may be found in
  ! Lifshitz&Pitaevskii, Physical Kinetics, Eq.42.5
  ! note that in the Russian edition they denote k_B T as Te and
  ! the factor 3 is missed in the denominator:
  ! 1/tau_ei = 2* CoulombLog * sqrt{m_e} (e^2/cEps)**2* Z**2 *Ni /&
  ! ( 3 * (2\pi k_B Te)**1.5 M_p). This exchange rate scales linearly
  ! with the plasma density, therefore, we introduce its ratio to
  ! the particle concentration. We calculate the temperature exchange
  ! rate by multiplying the expression for electron-ion effective
  ! collision rate,
  ! \nu_{ei} = CoulombLog/sqrt(cElectronMass)*  &
  !            ( cElectronCharge**2 / cEps)**2 /&
  !            ( 3 *(cTwoPi*cBoltzmann)**1.50 )* Ne/Te**1.5
  !  and then multiply in by the energy exchange coefficient
  !            (2*cElectronMass/cProtonMass)
  ! The calculation of the effective electron-ion collision rate is
  ! re-usable and can be also applied to calculate the resistivity:
  ! \eta = m \nu_{ei}/(e**2 Ne)
  !
  real :: cExchangeRateSi
  !
  ! See above about usage of the latter constant
  !
  integer, parameter:: Impl_=3

  integer        :: nIter = 20
  real           :: cTol=1.0e-6
  logical :: UseThomasAlg4Waves = .false.
contains
  !============================================================================
  subroutine init_threaded_lc
    use BATL_lib, ONLY:  MinI, MaxI, MinJ, MaxJ, MinK, MaxK
    use ModLookupTable,     ONLY: i_lookup_table
    use ModConst,           ONLY: cElectronMass, &
         cEps, cElectronCharge, cTwoPi, cProtonMass
    use ModMultiFluid,      ONLY: MassIon_I
    use ModFieldLineThread, ONLY:  nPointThreadMax, init_thread=>init
    use ModPhysics,         ONLY: &
         UnitTemperature_, Si2No_V, UnitEnergyDens_
    use ModVarIndexes,      ONLY: Pe_, p_
    use ModChromosphere,    ONLY: TeChromosphereSi

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'init_threaded_lc'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    allocate(Te_G(MinI:MaxI,MinJ:MaxJ,MinK:MaxK)); Te_G = 0.0

    allocate(ReflCoef_I(0:nPointThreadMax)); ReflCoef_I = 0.0
    allocate(   AMajor_I(0:nPointThreadMax));    AMajor_I = 0.0
    allocate(  AMinor_I(0:nPointThreadMax));   AMinor_I = 0.0

    allocate(   TeSi_I(nPointThreadMax));     TeSi_I = 0.0
    allocate(TeSiStart_I(nPointThreadMax));  TeSiStart_I = 0.0
    allocate(   TiSi_I(nPointThreadMax));     TiSi_I = 0.0
    allocate(TiSiStart_I(nPointThreadMax));  TiSiStart_I = 0.0
    allocate(   Cons_I(nPointThreadMax));     Cons_I = 0.0
    allocate( PSi_I(nPointThreadMax));   PSi_I = 0.0

    allocate(   SpecHeat_I(nPointThreadMax));   SpecHeat_I = 0.0
    allocate(DeltaEnergy_I(nPointThreadMax));DeltaEnergy_I = 0.0
    allocate(SpecIonHeat_I(nPointThreadMax));   SpecIonHeat_I = 0.0
    allocate(DeltaIonEnergy_I(nPointThreadMax));DeltaIonEnergy_I = 0.0
    allocate(ExchangeRate_I(nPointThreadMax));ExchangeRate_I = 0.0

    allocate( ResHeating_I(nPointThreadMax)); ResHeating_I = 0.0
    allocate( ResCooling_I(nPointThreadMax)); ResCooling_I = 0.0
    allocate(DResCoolingOverDLogT_I(nPointThreadMax))
    DResCoolingOverDLogT_I = 0.0
    allocate(ResEnthalpy_I(nPointThreadMax));ResEnthalpy_I = 0.0
    allocate(ResHeatCond_I(nPointThreadMax));ResHeatCond_I = 0.0
    allocate( ResGravity_I(nPointThreadMax)); ResGravity_I = 0.0

    allocate(     Xi_I(0:nPointThreadMax));     Xi_I = 0.0
    allocate(  VaLog_I(nPointThreadMax));    VaLog_I = 0.0
    allocate(    DXi_I(nPointThreadMax));      DXi_I = 0.0
    allocate(DissipationMinus_I(nPointThreadMax)); DissipationMinus_I = 0.0
    allocate(DissipationPlus_I(nPointThreadMax)); DissipationPlus_I = 0.0
    allocate(EnthalpyFlux_I(nPointThreadMax)); EnthalpyFlux_I = 0.0

    allocate(  Res_VI(Cons_:ConsAMinor_,nPointThreadMax));      Res_VI = 0.0
    allocate(DCons_VI(Cons_:ConsAMinor_,nPointThreadMax));    DCons_VI = 0.0

    allocate(U_VVI(Cons_:ConsAMinor_,Cons_:ConsAMinor_,nPointThreadMax))
    U_VVI = 0.0
    allocate(L_VVI(Cons_:ConsAMinor_,Cons_:ConsAMinor_,nPointThreadMax))
    L_VVI = 0.0
    allocate(M_VVI(Cons_:ConsAMinor_,Cons_:ConsAMinor_,nPointThreadMax))
    M_VVI = 0.0
    allocate(Flux_I(nPointThreadMax)); Flux_I = 0.0
    !
    ! Initialize transition region model:
    call init_tr(Z=Z, TeChromoSi = TeChromosphereSi)
    !
    ! Initialize thread structure
    !
    call init_thread

    !
    ! In hydrogen palsma, the electron-ion heat exchange is described by
    ! the equation as follows:
    ! dTe/dt = -(Te-Ti)/(tau_{ei})
    ! dTi/dt = +(Te-Ti)/(tau_{ei})
    ! The expression for 1/tau_{ei} may be found in
    ! Lifshitz&Pitaevskii, Physical Kinetics, Eq.42.5
    ! note that in the Russian edition they denote k_B T as Te and
    ! the factor 3 is missed in the denominator:
    ! 1/tau_ei = 2* CoulombLog * sqrt{m_e} (e^2/cEps)**2* Z**2 *Ni /&
    ! ( 3 * (2\pi k_B Te)**1.5 M_p). This exchange rate scales linearly
    ! with the plasma density, therefore, we introduce its ratio to
    ! the particle concentration. We calculate the temperature exchange
    ! rate by multiplying the expression for electron-ion effective
    ! collision rate,
    ! \nu_{ei} = CoulombLog/sqrt(cElectronMass)*  &
    !            ( cElectronCharge**2 / cEps)**2 /&
    !            ( 3 *(cTwoPi*cBoltzmann)**1.50 )* Ne/Te**1.5
    !  and then multiply in by the energy exchange coefficient
    !            (2*cElectronMass/cProtonMass)
    ! The calculation of the effective electron-ion collision rate is
    ! re-usable and can be also applied to calculate the resistivity:
    ! \eta = m \nu_{ei}/(e**2 Ne)
    !
    cExchangeRateSi = &
         CoulombLog/sqrt(cElectronMass)*  &!\
         ( cElectronCharge**2 / cEps)**2 /&! effective ei collision frequency
         ( 3 *(cTwoPi*cBoltzmann)**1.50 ) &!/
         *(2*cElectronMass/cProtonMass)  /&! *energy exchange per ei collision
         cBoltzmann
    !
    ! Dimensionless temperature floor
    !
    TeMin = TeSiMin*Si2No_V(UnitTemperature_)

    ConsMin = cTwoSevenths*HeatCondParSi*TeSiMin**3.50

    !
    !   Hydrostatic equilibrium in an isothermal corona:
    !    d(N_i*k_B*(Z*T_e +T_i) )/dr=G*M_sun*N_I*M_i*d(1/r)/dr
    ! => N_i*Te\propto exp(cGravPot/TeSi*(M_i[amu]/(1+Z))*\Delta(R_sun/r))
    !
    GravHydroStat = cGravPot*MassIon_I(1)/(Z + 1)
    !
    ! energy flux needed to raise the mass flux rho*u to the heliocentric
    ! distance r equals: rho*u*G*Msun*(1/R_sun -1/r)=
    !=k_B*N_i*M_i(amu)u*cGravPot*(1-R_sun/r)=
    !=P_e/T_e*cGravPot*u(M_i[amu]/Z)*(1/R_sun -1/r)
    !
    GravHydroDyn  = cGravPot*MassIon_I(1)/Z
    !
    ! With this constant, the dimensionless density
    ! equals RhoNoDimCoef*PeSi/TeSi
    !
    RhoNoDimCoef = Si2No_V(UnitEnergyDens_)/PeFraction*&
         TeFraction/Si2No_V(UnitTemperature_)
    call test_stop(NameSub, DoTest)
  end subroutine init_threaded_lc
  !============================================================================
  subroutine read_threaded_bc_param

    use ModReadParam, ONLY: read_var

    character(LEN=7)::TypeBc = 'limited'
    integer :: iError

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_threaded_bc_param'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call read_var('UseAlignedVelocity', UseAlignedVelocity)
    call read_var('DoConvergenceCheck', DoConvergenceCheck)
    call read_var('TypeBc'            , TypeBc            )
    select case(TypeBc)
    case('first')
       LimMin = 0; LimMax = 0
    case('second')
       LimMin = 1; LimMax = 1
    case('limited')
       LimMin = 0; LimMax = 1
    case default
       if(iProc==0)write(*,'(a)')&
            'Unknown TypeBc = '//TypeBc//', reset to limited'
    end select
    call read_var('cTol',cTol, iError)
    if(iError/=0)then
       cTol = 1.0e-6 ! Recover the default value
       RETURN
    end if
    call read_var('nIter', nIter, iError)
    if(iError/=0)then
       nIter = 20 ! Recover a default value
       RETURN
    end if
    call read_var('UseThomasAlg4Waves',UseThomasAlg4Waves, iError)
    if(iError/=0)&
       UseThomasAlg4Waves = .false. ! Recover the default value
    call test_stop(NameSub, DoTest)

  end subroutine read_threaded_bc_param
  !============================================================================
  !
  ! Main routine:
  ! solves MHD equations along thread, to link the state above the
  ! inner boundary of the global solar corona to the photosphere
  !
  subroutine solve_boundary_thread(j, k, iBlock, &
       iAction, TeSiIn, TiSiIn, PeSiIn, USiIn, AMinorIn, &
       DTeOverDsSiOut, PeSiOut,PiSiOut, RhoNoDimOut, AMajorOut)
    !
    ! USE:
    !
    use ModAdvance,          ONLY: nJ
    use ModTransitionRegion, ONLY: HeatCondParSi
    use ModPhysics,      ONLY: InvGammaMinus1,&
         No2Si_V, UnitX_,Si2No_V, UnitB_, UnitTemperature_
    use ModLookupTable,  ONLY: interpolate_lookup_table
    !INPUT:
    !
    ! Cell and block indexes for the boundary point
    !
    integer,intent(in):: j, k, iBlock, iAction
    !
    ! Parameters of the state in the true cell near the boundary:
    ! TeSiIn: Temperature in K
    ! USiIn:  Velocity progection on the magnetic field direction.
    ! It is positive if the wind blows outward the Sun.
    ! AMinorIn: for the wave propagating toward the Sun
    !            WaveEnergyDensity = (\Pi/B)\sqrt{\rho} AMinor**2
    !
    real,   intent(in):: TeSiIn, TiSiIn, PeSiIn, USiIn, AMinorIn
    !
    !OUTPUT:
    ! DTeOverDsSiOut: Temperature derivative along the thread, at the end point
    !                Used to find the electron temperature in the ghostcell
    ! PeSiOut: The electron pressure
    ! AMajorOut: For the wave propagating outward the Sun
    !            EnergyDensity = (\Pi/B)\sqrt{\rho} AMajor**2
    !
    real,  intent(out):: &
         DTeOverDsSiOut, PeSiOut, PiSiOut, RhoNoDimOut, AMajorOut

    !
    ! Arrays needed to use lookup table
    !
    real    :: Value_V(LengthPAvrSi_:DLogLambdaOverDLogT_)
    !
    ! Limited Speed
    !
    real    :: USi
    !
    !---------Used in 1D numerical model------------------------
    !
    !
    ! Number of TEMPERATURE nodes (first one is on the top of TR
    ! the last one is in the physical cell of the SC model
    !
    integer        :: nPoint, iPoint
    !
    ! Corrrect density and pressure values in the ghost
    !
    real :: GhostCellCorr, BarometricFactor, DeltaTeFactor,             &
         Limiter, DensityRatio, RhoTrueCell,                            &
         FirstOrderRho, FirstOrderPeSi, SecondOrderRho, SecondOrderPeSi

    !
    ! Electron heat condution flux from Low Corona to TR:
    !
    real :: HeatFlux2TR

    integer :: nIterHere
    logical :: DoCheckConvHere

    character(len=12) :: NameTiming
    character(len=*), parameter:: NameSub = 'solve_boundary_thread'
    !--------------------------------------------------------------------------
    !
    ! Initialize all output parameters from 0D solution
    !
    write(NameTiming,'(a,i2.2)')'set_thread',j + nJ*(k - 1)
    call timing_start(NameTiming)
    call interpolate_lookup_table(iTableTR, TeSiIn, Value_V, &
           DoExtrapolate=.false.)
    !
    ! First value is now the product of the thread length in meters times
    ! a geometric mean pressure, so that
    !
    PeSiOut        = Value_V(LengthPAvrSi_)*SqrtZ/&
         BoundaryThreads_B(iBlock)% LengthSi_III(0,j,k)
    PiSiOut = PeSiOut/(Z*TeSiIn)*TiSiIn
    USi = USiIn
    if(USi>0)then
       USi = min(USi,0.1*Value_V(UHeat_))
    else
       USi = max(USi, -0.1*Value_V(HeatFluxLength_)/&
            (BoundaryThreads_B(iBlock)% LengthSi_III(0,j,k)*PeSiIn))
    end if
    RhoNoDimOut    = RhoNoDimCoef*PeSiOut/TeSiIn
    AMajorOut      = 1.0
    TeSiMax        = &
          BoundaryThreads_B(iBlock) % TMax_II(j,k)*No2Si_V(UnitTemperature_)
    ConsMax = cTwoSevenths*HeatCondParSi*TeSiMax**3.50

    nPoint = BoundaryThreads_B(iBlock)% nPoint_II(j,k)
    if(iAction/=DoInit_)then
       !
       ! Retrieve temperature and pressure distribution
       !
       TeSi_I(1:nPoint) = BoundaryThreads_B(iBlock)%State_VIII(TeSi_,1-nPoint:0,j,k)
       TiSi_I(1:nPoint) = BoundaryThreads_B(iBlock)%State_VIII(TiSi_,1-nPoint:0,j,k)
       PSi_I(1:nPoint)  = BoundaryThreads_B(iBlock)%State_VIII(PSi_,1-nPoint:0,j,k)
       if(UseThomasAlg4Waves)then
          AMajor_I(1:nPoint) = BoundaryThreads_B(iBlock)%State_VIII(AMajor_,1-nPoint:0,j,k)
          AMinor_I(1:nPoint) = BoundaryThreads_B(iBlock)%State_VIII(AMinor_,1-nPoint:0,j,k)
       else
          AMajor_I(0:nPoint) = BoundaryThreads_B(iBlock)%State_VIII(AMajor_,-nPoint:0,j,k)
          AMinor_I(0:nPoint) = BoundaryThreads_B(iBlock)%State_VIII(AMinor_,-nPoint:0,j,k)
       end if
       if(iAction/=Enthalpy_)then
          TeSi_I(nPoint)   = TeSiIn
          TiSi_I(nPoint)   = TiSiIn
       end if
       DoCheckConvHere = .false.
       nIterHere       = 1
    else
       DoCheckConvHere = DoConvergenceCheck
       nIterHere       = nIter
    end if
    AMinor_I(nPoint)    = AMinorIn
    select case(iAction)
    case(DoInit_)
       !
       ! As a first approximation, recover Te from the analytical solution
       !
       call analytical_te_ti
       !
       ! The analytical solution assumes constant pressure and
       ! no heating. Calculate the pressure distribution
       !
       call set_pressure
       !
       ! Get wave from analytical solution with noreflection
       call get_dxi_and_xi
       call analytical_waves
       call advance_thread(IsTimeAccurate=.false.)
       call solve_heating(nIterIn=nIterHere)
       BoundaryThreads_B(iBlock)%State_VIII(TeSi_,1-nPoint:0,j,k) = TeSi_I(1:nPoint)
       BoundaryThreads_B(iBlock)%State_VIII(TiSi_,1-nPoint:0,j,k) = TiSi_I(1:nPoint)
       BoundaryThreads_B(iBlock)%State_VIII(PSi_,1-nPoint:0,j,k)  = PSi_I(1:nPoint)
       if(UseThomasAlg4Waves)then
          BoundaryThreads_B(iBlock)%State_VIII(AMajor_,1-nPoint:0,j,k) = AMajor_I(1:nPoint)
          BoundaryThreads_B(iBlock)%State_VIII(AMinor_,1-nPoint:0,j,k) = AMinor_I(1:nPoint)
       else
          BoundaryThreads_B(iBlock)%State_VIII(AMajor_,-nPoint:0,j,k) = AMajor_I(0:nPoint)
          BoundaryThreads_B(iBlock)%State_VIII(AMinor_,-nPoint:0,j,k) = AMinor_I(0:nPoint)
       end if
    case(Enthalpy_)
       call solve_heating(nIterIn=nIterHere)
       !
       ! Do not store temperature
       !
    case(Impl_)
       call advance_thread(IsTimeAccurate=.true.)
       !
       ! Output for temperature gradient, all the other outputs
       ! are meaningless
       !
       DTeOverDsSiOut = max(0.0,(TeSi_I(nPoint) - TeSi_I(nPoint-1))/&
            (BoundaryThreads_B(iBlock)% LengthSi_III(0,j,k) - &
            BoundaryThreads_B(iBlock)% LengthSi_III(-1,j,k)))
       !
       ! Do not store temperatures
       !
       call timing_stop(NameTiming)
       RETURN
    case(Heat_)
       call advance_thread(IsTimeAccurate=.true.)

       ! Calculate AWaves and store pressure and temperature
       call solve_heating(nIterIn=nIterHere)
       BoundaryThreads_B(iBlock)%State_VIII(TeSi_,1-nPoint:0,j,k) = TeSi_I(1:nPoint)
       BoundaryThreads_B(iBlock)%State_VIII(TiSi_,1-nPoint:0,j,k) = TiSi_I(1:nPoint)
       BoundaryThreads_B(iBlock)%State_VIII(PSi_,1-nPoint:0,j,k)  = PSi_I(1:nPoint)
       if(UseThomasAlg4Waves)then
          BoundaryThreads_B(iBlock)%State_VIII(AMajor_,1-nPoint:0,j,k) = AMajor_I(1:nPoint)
          BoundaryThreads_B(iBlock)%State_VIII(AMinor_,1-nPoint:0,j,k) = AMinor_I(1:nPoint)
       else
          BoundaryThreads_B(iBlock)%State_VIII(AMajor_,-nPoint:0,j,k) = AMajor_I(0:nPoint)
          BoundaryThreads_B(iBlock)%State_VIII(AMinor_,-nPoint:0,j,k) = AMinor_I(0:nPoint)
       end if
    case default
       write(*,*)'iAction=',iAction
       call stop_mpi('Unknown action in '//NameSub)
    end select
    !
    ! Outputs
    !
    !
    ! First order solution: ghost cell from the first layer are filled
    ! in with the solution of the threaded field line equation at the
    ! end point.
    !
    FirstOrderRho   = RhoNoDimCoef*PSi_I(nPoint)*Z/&
         (Z*TeSi_I(nPoint) + TiSi_I(nPoint))
    FirstOrderPeSi  = PSi_I(nPoint)*TeSi_I(nPoint)*Z/&
         (Z*TeSi_I(nPoint) + TiSi_I(nPoint))

    !
    ! Second order solution consists of two contributions, the first of them
    ! being the correction of true cell values. Calculate the true density:
    !
    RhoTrueCell = RhoNoDimCoef*PeSiIn/TeSiIn
    !
    ! The pressure in the ghost cell should be corrected corrected for
    ! a barometric scale factor, as a consequence of the hydrostatic
    ! equiliblrium condition in the physical cell. Cell corr as calculated
    ! below is the negative of DeltaR of BATSRUS / delta r of the thread. Thus,
    !
    GhostCellCorr =  BoundaryThreads_B(iBlock)% DeltaR_II(j,k)/&
         (1/BoundaryThreads_B(iBlock)%RInv_III(-1,j,k) - &
         1/BoundaryThreads_B(iBlock)%RInv_III(0,j,k) )  ! < O!
    !
    !
    !      ghost cell | phys.cell
    !           *<-delta R->*
    !      PGhost=exp(-dLogP/dR*DeltaR)*PPhys
    !
    BarometricFactor = exp(&
         (log(PSi_I(nPoint)) - log(PSi_I(nPoint-1)))*GhostCellCorr )
    !
    ! Limit Barometric factor
    !
    BarometricFactor=min(BarometricFactor,2.0)

    SecondOrderPeSi  = PeSiIn*BarometricFactor
    !
    ! In the ghost cell value of density in addition to the
    ! barometric factor the temperature gradient is accounted for,
    ! which is cotrolled by the heat flux derived from the TFL model:
    !

    GhostCellCorr =  BoundaryThreads_B(iBlock)% DeltaR_II(j,k)/min(          &
         (1/BoundaryThreads_B(iBlock)%RInv_III(-1,j,k) -                     &
         1/BoundaryThreads_B(iBlock)%RInv_III(0,j,k) ),-0.7*                 &
         Si2No_V(UnitX_)*(BoundaryThreads_B(iBlock)% LengthSi_III(0,j,k) -   &
         BoundaryThreads_B(iBlock)% LengthSi_III(-1,j,k)))

    DeltaTeFactor = TeSi_I(nPoint)/max(TeSiMin, TeSi_I(nPoint) + &
         max(TeSi_I(nPoint  ) - TeSi_I(nPoint-1),0.0)*GhostCellCorr)
    !
    ! Limit DeltaTeFactor
    !
    DeltaTeFactor = min(DeltaTeFactor,2.0)
    !
    ! Approximately TeSiGhost = TeSiIn/DeltaTeFactor, so that:
    !
    SecondOrderRho = RhoTrueCell*BarometricFactor*DeltaTeFactor
    !
    ! Add numerical diffusion, which forcing the density in the true cell
    ! to approach the "first order" values predicted by the TFL model.
    !
    SecondOrderRho  = SecondOrderRho  + (FirstOrderRho - RhoTrueCell)
    SecondOrderPeSi = SecondOrderPeSi + &
         (FirstOrderPeSi - PeSiIn)/DeltaTeFactor
    !
    ! In the latter equation the 1/DeltaTeFactor multipler is introduced
    ! to keep the ratio of the corrected values to be equal to
    ! TeSiGhost = TeSiIn/DeltaTeFactor
    ! as predicted by the TFL model
    !
    !
    ! Now, limit the difference between the first and second order
    ! solutions, depending on the ratio between the true cell value
    ! density and the first order ghost cell value of density
    !
    DensityRatio = RhoTrueCell/FirstOrderRho
    !
    ! If PeSiIn>PSi_I(nPoint), then we apply limitation, which completely
    ! eleminates the second order correction if this ratio becomes as high
    ! as the barometric factor:
    !
    Limiter = min(LimMax, max(LimMin, &
         (BarometricFactor - DensityRatio)/(BarometricFactor - 1)))
    RhoNoDimOut = Limiter*(SecondOrderRho - FirstOrderRho) +&
         FirstOrderRho
    PeSiOut     = Limiter*(SecondOrderPeSi - FirstOrderPeSi) + &
         FirstOrderPeSi
    PiSiOut     = PeSiOut/(Z*TeSiIn)*TiSiIn
    if(RhoNoDimOut>1e8.or.RhoNoDimOut<1e-8)then
       write(*,*)'TeSiMax=       ',TeSiMax
       write(*,*)'iAction=',iAction
       write(*,*)'Xyz_DGB(:,1,j,k)',Xyz_DGB(:,1,j,k,iBlock)
       write(*,*)'RhoNoDimOut=', RhoNoDimOut,' PeSiOut=',PeSiOut
       write(*,*)'USiIn, USi=', USiIn,' ',USi
       write(*,*)'PeSiIn=',PeSiIn
       write(*,*)'TeSiIn=',TeSiIn
       write(*,*)'First order Rho, PSi=',FirstOrderRho, FirstOrderPeSi
       write(*,*)'Second order Rho, PSi=',SecondOrderRho, SecondOrderPeSi
       write(*,*)'BarometricFactor=',BarometricFactor
       write(*,*)'DeltaTeFactor=',DeltaTeFactor
       write(*,*)&
            'iPoint TeSi TeSiStart PSi ResHeating ResEnthalpy'
       do iPoint=1,nPoint
          write(*,'(i4,6es15.6)')iPoint, TeSi_I(iPoint),&
               TeSiStart_I(iPoint),&
               PSi_I(iPoint),ResHeating_I(iPoint), ResEnthalpy_I(iPoint)
       end do
       call stop_mpi('Failure')
    end if
    call timing_stop(NameTiming)
  contains
    !==========================================================================
    subroutine analytical_te_ti
      integer :: iPoint
      !------------------------------------------------------------------------
      TeSi_I(nPoint) = TeSiIn; TiSi_I(nPoint) = TiSiIn
      do iPoint = nPoint-1, 1, -1
         call interpolate_lookup_table(&
              iTable=iTableTR,         &
              iVal=LengthPAvrSi_,      &
              ValIn=PeSiOut/SqrtZ*     &
              BoundaryThreads_B(iBlock)% LengthSi_III(iPoint-nPoint,j,k), &
              Value_V=Value_V,         &
              Arg1Out=TeSi_I(iPoint),  &
              DoExtrapolate=.false.)
      end do
      TeSi_I(1:nPoint) = max(TeSiMin, TeSi_I(1:nPoint))
      TiSi_I(1:nPoint-1) = TeSi_I(1:nPoint-1)
    end subroutine analytical_te_ti
    !==========================================================================
    subroutine set_pressure
      integer::iPoint
      !------------------------------------------------------------------------
      !
      ! First variable in Value_V  is now the product of the thread length in
      ! meters times a geometric mean pressure, so that
      !
      PSi_I(1) = Value_V(LengthPAvrSi_)*(1 + Z)/(SqrtZ*&
           BoundaryThreads_B(iBlock)% LengthSi_III(1-nPoint,j,k))
      !
      !   Hydrostatic equilibrium in an isothermal corona:
      !    d(N_i*k_B*(Z*T_e +T_i) )/dr=G*M_sun*N_I*M_i*d(1/r)/dr
      ! => N_i*Te\propto exp(cGravPot/TeSi*(M_i[amu]/(1+Z))*\Delta(R_sun/r))
      !
      ! GravHydroStat = cGravPot*MassIon_I(1)/(Z + 1)
      do iPoint = 2, nPoint
         PSi_I(iPoint) = PSi_I(iPoint-1)*&
            exp( -BoundaryThreads_B(iBlock)%TGrav_III(iPoint-nPoint,j,k)*&
           (Z + 1)/(Z*TeSi_I(iPoint) + TiSi_I(iPoint)))
      end do
    end subroutine set_pressure
    !==========================================================================
    subroutine get_dxi_and_xi
      integer:: iPoint
      real    :: SqrtRho, RhoNoDim, vAlfven

      !

      !------------------------------------------------------------------------
      do iPoint=1,nPoint
         !
         ! 1. Calculate sqrt(RhoNoDim)
         !
         RhoNoDim = RhoNoDimCoef*PSi_I(iPoint)/&
              (Z*TeSi_I(iPoint) + TiSi_I(iPoint))
         if(RhoNoDim<=0.0)then
            write(*,*)'iPoint=',iPoint,' PSi_I(iPoint)=',&
                 PSi_I(iPoint),' TeSi_I(iPoint)=',TeSi_I(iPoint),&
                 ' TiSi_I(iPoint)=',TiSi_I(iPoint)
            call stop_mpi('Non-positive Density in '//NameSub)
         end if
         SqrtRho = sqrt(RhoNoDim)
         !
         ! 2. Calculate Alfven wave speed
         !
         vAlfven = BoundaryThreads_B(iBlock)% B_III(iPoint-nPoint,j,k)/SqrtRho
         VaLog_I(iPoint) = log(vAlfven)
         !
         ! 3. Calculate dimensionless length (in terms of the dissipation length
         !
         DXi_I(iPoint) = &
              BoundaryThreads_B(iBlock)% DXiCell_III(iPoint-nPoint,j,k)/&
              sqrt(vAlfven)
      end do
      if(UseThomasAlg4Waves)then
         !
         ! Gridpoints for waves are at the centers of temperature cells
         !
         Xi_I(1) = 0.50*DXi_I(1)
         do iPoint = 2, nPoint
            Xi_I(iPoint) = Xi_I(iPoint-1) + &
                 0.50*(DXi_I(iPoint-1) + DXi_I(iPoint))
         end do
         !
         ! Correct the end points by the half intervals
         !
         Xi_I(1) = 0.0; Xi_I(nPoint) = Xi_I(nPoint) + 0.50*DXi_I(nPoint)
      else
         !
         ! Gridpoints for waves are at the faces between temperature cells
         ! except for zeroth and nPoint'th ones
         !
         Xi_I(0) = 0.0
         do iPoint = 1, nPoint
            Xi_I(iPoint) = Xi_I(iPoint-1) + DXi_I(iPoint)
         end do
      end if
    end subroutine get_dxi_and_xi
    !==========================================================================
    subroutine analytical_waves
      integer:: iPoint
      !
      ! Sum of a_+ and a_- and iterative values for it
      !
      real    :: Sigma, SigmaOld, Aux, XiTot

      ! 4.1. As zero order approximation we solve waves with no reflection
      !
      ! solve equation
      !(\Sigma -1)*(\Sigma -AMinorIn) - AMinor*exp(-\Sigma*Xi_I(nPoint))=0
      !
      ! The sought value is in between 1 and 1 + AMinorIn

      !------------------------------------------------------------------------
      Sigma = 1 + AMinorIn; SigmaOld = 1.0; XiTot = Xi_I(nPoint)
      do while(abs(Sigma - SigmaOld) > 0.01*cTol)
         SigmaOld = Sigma
         Aux = exp(-SigmaOld*XiTot)
         Sigma = SigmaOld -( & ! Residual function
              (SigmaOld - 1)*(SigmaOld - AMinorIn) - AMinorIn*Aux )/&
              (2*SigmaOld - (1 - AMinorIn) + XiTot*AMinorIn*Aux)
      end do
      !
      ! 4.2. Apply boundary conditions
      !
      AMinor_I(nPoint) = AMinorIn
      !
      ! 4.3. Now, apply formulae, which are valid for no-reflection case:
      !
      AMajor_I(1:nPoint) = Sigma/(1 + (Sigma - 1)*exp(Sigma*Xi_I(1:nPoint)))
      if(UseThomasAlg4Waves)then
         AMinor_I(1:nPoint-1) = AMinorIn*Sigma/(AMinorIn + (Sigma - AMinorIn)*&
              exp(Sigma*(XiTot - Xi_I(1:nPoint-1))))
      else
         AMajor_I(0) = 1
         AMinor_I(0:nPoint-1) = AMinorIn*Sigma/(AMinorIn + (Sigma - AMinorIn)*&
              exp(Sigma*(XiTot - Xi_I(0:nPoint-1))))
      end if
    end subroutine analytical_waves
    !==========================================================================
    !=================Calculation of sources and Jacobian matrices=============
    subroutine get_reflection
      use ModCoronalHeating,  ONLY: rMinWaveReflection
      integer:: iPoint
      !

      !------------------------------------------------------------------------
      if(rMinWaveReflection*BoundaryThreads_B(iBlock)%RInv_III(0,j,k) > 1.0 &
           )then
         !
         ! All thread points are below rMinWaveReflection
         !
         ReflCoef_I(0:nPoint) = 0
      else
         !
         ! Calculate the reflection coefficient
         !
         ReflCoef_I(1) = abs(VaLog_I(2) - VaLog_I(1))/&
              (0.50*DXi_I(2) + DXi_I(1))
         do iPoint = 2, nPoint -2
            ReflCoef_i(iPoint) = &
                 abs(VaLog_I(iPoint+1) - VaLog_I(iPoint))/&
                 (0.50*(DXi_I(iPoint+1) +  DXi_I(iPoint)))
         end do
         ReflCoef_I(nPoint-1) = abs(VaLog_I(nPoint) - VaLog_I(nPoint-1))/&
              (0.50*DXi_I(nPoint-1) + DXi_I(nPoint))
         !
         !  Some thread points may be below rMinWaveReflection
         if(rMinWaveReflection > 1.0)&
              ReflCoef_I(1:nPoint-1) = ReflCoef_I(1:nPoint-1)*0.5*&
              (1 + tanh(50*(1 - rMinWaveReflection*&
              BoundaryThreads_B(iBlock)%RInv_III(2-nPoint:0,j,k))))
         ReflCoef_I(0) =  ReflCoef_I(1)
         ReflCoef_I(nPoint) = ReflCoef_I(nPoint-1)
      end if
    end subroutine get_reflection
    !==========================================================================
    subroutine get_heat_cond
      !------------------------------------------------------------------------
      M_VVI(Cons_:LogP_,Cons_:LogP_,:) = 0.0
      ResHeatCond_I = 0.0
      U_VVI(Cons_:LogP_,Cons_:LogP_,:) = 0.0
      L_VVI(Cons_:LogP_,Cons_:LogP_,:) = 0.0
      !----------------
      !
      ! Contribution from heat conduction fluxes
      !
      !
      ! Flux linearizations over small dCons
      ! Dimensionless flux= dCons/ds(1/( (PoyntingFlux/B)B)
      !
      U_VVI(Cons_,Cons_,1:nPoint-1) = &
           -BoundaryThreads_B(iBlock)% BDsFaceInvSi_III(1-nPoint:-1,j,k)
      L_VVI(Cons_,Cons_,2:nPoint-1) = U_VVI(Cons_,Cons_,1:nPoint-2)
      M_VVI(Cons_,Cons_,2:nPoint-1) = &
           -U_VVI(Cons_,Cons_,2:nPoint-1) - L_VVI(Cons_,Cons_,2:nPoint-1)
      !
      ! Right heat fluxes
      !
      ResHeatCond_I(1:nPoint-1) = &
           (Cons_I(1:nPoint-1) - Cons_I(2:nPoint))*U_VVI(Cons_,Cons_,1:nPoint-1)
      !
      ! Add left heat flux to the TR
      HeatFlux2TR = Value_V(HeatFluxLength_)*&
           BoundaryThreads_B(iBlock)% BDsFaceInvSi_III(-nPoint,j,k)
      ResHeatCond_I(1) = ResHeatCond_I(1) -  HeatFlux2TR
      !
      ! Linearize left heat flux to the TR
      !

      M_VVI(Cons_,Cons_,1) = -U_VVI(Cons_,Cons_,1) + Value_V(DHeatFluxXOverU_)*&
           BoundaryThreads_B(iBlock)% BDsFaceInvSi_III(-nPoint,j,k)
      !
      ! Add other left heat fluxes
      !
      ResHeatCond_I(2:nPoint-1) = ResHeatCond_I(2:nPoint-1) + &
           (Cons_I(2:nPoint-1) - Cons_I(1:nPoint-2))*&
           L_VVI(Cons_,Cons_,2:nPoint-1)
      !
      ! LogP_ terms
      !
      M_VVI(LogP_,LogP_,1:nPoint-1) =  1.0
      !
      ! 1. At the TR:
      ! We satisfy the equation, d(LogP) = d(Cons)*(dPAvr/dCons)_{TR}/PAvr
      !
      M_VVI(LogP_,Cons_,1) = -1/&
              Value_V(HeatFluxLength_) + TiSi_I(1)/&
              (3.5*Cons_I(1)*(Z*TeSi_I(1) + TiSi_I(1)))
      M_VVI(LogP_,Ti_,1)   = -1/(Z*TeSi_I(1) + TiSi_I(1))

      !
      ! 2:
      ! For other points we satisfy the hydrostatic equilibrium condition
      ! LogPe^{i-1}=LogPe^i+TGrav/Te^i
      ! dLogPe^i - dCons^i(TGrav/(Te^i)^2)*dTe/dCons -dLogPe^{i-1}=0
      !
      M_VVI(LogP_,Cons_,2:nPoint-1) = -(Z + 1)*Z*&
           BoundaryThreads_B(iBlock)% TGrav_III(2-nPoint:-1,j,k)/&
           (Z*TeSi_I(2:nPoint-1) + TiSi_I(2:nPoint-1))**2*&
           TeSi_I(2:nPoint-1)/(3.50*Cons_I(2:nPoint-1))
      M_VVI(LogP_,Ti_,2:nPoint-1)   = -(Z + 1)*&
           BoundaryThreads_B(iBlock)% TGrav_III(2-nPoint:-1,j,k)/&
           (Z*TeSi_I(2:nPoint-1) + TiSi_I(2:nPoint-1))**2

      L_VVI(LogP_,LogP_,2:nPoint-1) = -1.0
      !
      ! Cooling
      ! 1. Source term:
      !
      ResCooling_I = 0.0;
      do iPoint = 1, nPoint-1
         if(TeSi_I(iPoint)>1.0e8)then
            write(*,*)'Failure in heat condusction setting'
            write(*,*)'In the point Xyz=',Xyz_DGB(:,1,j,k,iBlock)
            write(*,*)'TeSiIn, PeSiIn = ', TeSiIn, PeSiIn
            write(*,*)'TeSi_I=',TeSi_I(1:nPoint)
            call stop_mpi('Stop!!!')
         end if
         call interpolate_lookup_table(iTableTR, TeSi_I(iPoint), &
              Value_V, &
              DoExtrapolate=.false.)
         ResCooling_I(iPoint) = &
              -BoundaryThreads_B(iBlock)%DsCellOverBSi_III(iPoint-nPoint,j,k)&
              *Value_V(LambdaSI_)*Z*&
              (PSi_I(iPoint)/(Z*TeSi_I(iPoint) + TiSi_I(iPoint)))**2
         DResCoolingOverDLogT_I(iPoint) = &
              ResCooling_I(iPoint)*Value_V(DLogLambdaOverDLogT_)
      end do
      !
      ! 2. Source term derivatives:
      !
      M_VVI(Cons_,LogP_,1:nPoint-1) = &
           -2*ResCooling_I(1:nPoint-1) !=-dCooling/dLogPe
      M_VVI(Cons_,Cons_,1:nPoint-1) = M_VVI(Cons_,Cons_,1:nPoint-1) + &
           (-DResCoolingOverDLogT_I(1:nPoint-1) + 2*ResCooling_I(1:nPoint-1)/&
           (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))*Z*TeSi_I(1:nPoint-1))/&
           (3.50*Cons_I(1:nPoint-1))   !=-dCooling/dCons
      M_VVI(Cons_,Ti_,1:nPoint-1) = M_VVI(Cons_,Ti_,1:nPoint-1) + &
           2*ResCooling_I(1:nPoint-1)/&
           (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))   !=-dCooling/d log Ti
    end subroutine get_heat_cond
    !==========================================================================
    subroutine solve_heating(nIterIn)
      use ModCoronalHeating,  ONLY: rMinWaveReflection
      integer, intent(in)::nIterIn
      integer:: iPoint
      !------------------------------------------------------------------------
      call get_dxi_and_xi
      call get_reflection
      call solve_a_plus_minus(&
           AMinorBC=AMinorIn,              &
           AMajorBC=AMajorOut,             &
           nIterIn=nIterIn)
    end subroutine solve_heating
    !==========================================================================
    real function dissipation_major(AMajor, AMinor, Reflection, DeltaXi)
      real, intent(in)         ::   AMajor, AMinor, Reflection, DeltaXi
      !------------------------------------------------------------------------
      dissipation_major = (-AMinor*&
           (max(0.0,AMajor - MaxImbalance*AMinor)      &
           -max(0.0,AMinor - MaxImbalance*AMajor)  )*  &
           min(0.5*Reflection/max(AMinor,AMajor), 1.0) &
           - AMinor*AMajor)*DeltaXi
    end function dissipation_major
    !==========================================================================
    real function dissipation_minor(AMajor, AMinor, Reflection, DeltaXi)
      real, intent(in)         ::   AMajor, AMinor, Reflection, DeltaXi
      !------------------------------------------------------------------------
      dissipation_minor = ( AMajor*&
           (max(0.0,AMajor - MaxImbalance*AMinor)      &
           -max(0.0,AMinor - MaxImbalance*AMajor)  )*  &
           min(0.5*Reflection/max(AMinor,AMajor), 1.0) &
           - AMinor*AMajor)*DeltaXi
    end function dissipation_minor
    !==========================================================================
    subroutine get_aw_dissipation(AMajor, AMinor, Reflection, DeltaXi, &
         DissipationPlus, DissipationMinus, M_VV)
      ! Solves sources and Jacobian for solveng a system of equations:
      ! dAMajor/d Xi = DissipationPlus
      !-dAMinor/d Xi = DissipationMinus
      !INPUTS:
      ! Wave amplitudes
      real, intent(in)  :: AMajor, AMinor
      ! Reflection coefficient
      real, intent(in)  :: Reflection
      ! Dimensionless mesh size
      real, intent(in)  :: DeltaXi
      !OUTPUTS:
      ! Sources
      real, intent(out) :: DissipationPlus, DissipationMinus
      ! Jacobian
      real, intent(out) :: M_VV(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_)
      !------------------------------------------------------------------------
      if(AMajor > MaxImbalance*AMinor)then
         ! AMajor is dominant. Figure out if the
         ! reflection shoud be limited:
         if(0.5*Reflection < AMajor)then
            !
            ! Unlimited reflection
            !`
            DissipationPlus = (&
                 -AMinor*(1 - MaxImbalance*AMinor/AMajor)*0.5*Reflection &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationPlus/d amajor = aminor*&
            ! (1 + 0.5*Reflection*MaxImbalance*aMinor/aMajor**2)*DeltaXi
            !
            M_VV(ConsAMajor_,ConsAMajor_) = 1 + AMinor*(1 +  &
                 0.5*Reflection*MaxImbalance*aMinor/aMajor**2)*DeltaXi
            !
            !-dDissipationPlus/d aminor = ( (1 - 2*MaxImbalance*aMinor/aMajor)&
            !      *0.5*Reflection + aMajor)*DeltaXi >0
            !
            M_VV(ConsAMajor_,ConsAMinor_) = ((1 - 2*MaxImbalance*aMinor/aMajor)&
                 *0.5*Reflection + aMajor)*DeltaXi

            DissipationMinus = (&
                 (AMajor - MaxImbalance*AMinor)*0.5*Reflection &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationMinus/d aMinor = (AMajor + MaxImbalance  &
            !    *0.5*Reflection)*DeltaXi
            !
            M_VV(ConsAMinor_,ConsAMinor_) = 1 + (AMajor + MaxImbalance &
                 *0.5*Reflection)*DeltaXi
            !
            !-dDissipationMinus/d aMajor = (aMinor - 0.5*Reflection)*DeltaXi
            !
            M_VV(ConsAMinor_,ConsAMajor_) = (aMinor - 0.5*Reflection) &
                 *DeltaXi
         else
            !
            ! Limited reflection
            !
            DissipationPlus = (&
                 -AMinor*(AMajor - MaxImbalance*AMinor) &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationPlus/d amajor = 2*aminor*DeltaXi
            !
            M_VV(ConsAMajor_,ConsAMajor_) = 1 + 2*aminor*DeltaXi
            !
            !-dDissipationPlus/d aminor = 2*(AMajor - MaxImbalance*AMinor)&
            !     *DeltaXi  >0
            !
            M_VV(ConsAMajor_,ConsAMinor_) = 2*(AMajor - MaxImbalance*AMinor) &
                 *DeltaXi

            DissipationMinus = (&
                 AMajor*(AMajor - MaxImbalance*AMinor) &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationMinus/d aMinor = AMajor*(1 + MaxImbalance) &
            !   *DeltaXi
            !
            M_VV(ConsAMinor_,ConsAMinor_) = 1 + AMajor*(1 + MaxImbalance) &
                 *DeltaXi
            !
            !-dDissipationMinus/d aMajor = (AMinor*(1 + MaxImbalance) - &
            !       2*AMajor)*DeltaXi < 0
            !
            M_VV(ConsAMinor_,ConsAMajor_) = (AMinor*(1 + MaxImbalance)  &
                 -2*AMajor)*DeltaXi
         end if
      elseif(AMinor > MaxImbalance*AMajor)then
         ! AMinor is dominant. Figure out if the
         ! reflection shoud be limited:
         if(0.5*Reflection < AMinor)then
            !
            ! Unlimited reflection
            !`
            DissipationPlus = (&
                 (AMinor - MaxImbalance*AMajor)*0.5*Reflection &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationPlus/d amajor = 1 (aMinor + MaxImbalance &
            !      *0.5*Reflection)*DeltaXi
            !
            M_VV(ConsAMajor_,ConsAMajor_) = 1 + (aMinor + MaxImbalance &
                 *0.5*Reflection)*DeltaXi
            !
            !-dDissipationPlus/d aminor = (amajor - 0.5*Reflection)
            !       *DeltaXi
            !
            M_VV(ConsAMajor_,ConsAMinor_) = (amajor - 0.5*Reflection) &
                 *DeltaXi

            DissipationMinus = (&
                 -AMajor*(1 - MaxImbalance*AMajor/AMinor)*0.5*Reflection &
                 - AMinor*AMajor)*DeltaXi
            !
            !-d DissipationMinus/d aMinor = AMajor*(1 + 0.5*Reflection &
            !    *MaxImbalance*AMajor/AMinor**2)*DeltaXi
            !
            M_VV(ConsAMinor_,ConsAMinor_) = 1 + AMajor*(1 + 0.5*Reflection &
                 *MaxImbalance*AMajor/AMinor**2)*DeltaXi
            !
            !-d DissipationMinus/d aMajor = (AMinor + (1 - 2*MaxImbalance &
            !    *AMajor/AMinor)*0.5*Reflection)*DeltaXi
            !
            M_VV(ConsAMinor_,ConsAMajor_) = (AMinor + (1 - 2*MaxImbalance &
                 *AMajor/AMinor)*0.5*Reflection)*DeltaXi
         else
            !
            ! Limited reflection
            !
            DissipationPlus = (&
                 AMinor*(AMinor - MaxImbalance*AMajor) &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationPlus/d amajor = aMinor*(1 + MaxImbalance)*DeltaXi
            !
            M_VV(ConsAMajor_,ConsAMajor_) = 1 + aMinor*(1 + MaxImbalance) &
                 *DeltaXi
            !
            !-dDissipationPlus/d aminor = (aMajor*(1 +  MaxImbalance) &
            ! -2*AMinor)*DeltaXi < 0
            !
            M_VV(ConsAMajor_,ConsAMinor_) = (aMajor*(1 +  MaxImbalance) &
                 -2*AMinor)*DeltaXi

            DissipationMinus = (&
                 -AMajor*(AMinor - MaxImbalance*AMajor)  &
                 - AMinor*AMajor)*DeltaXi
            !
            !-dDissipationMinus/d aMinor = 2*AMajor*DeltaXi
            !
            M_VV(ConsAMinor_,ConsAMinor_) = 1 + 2*AMajor*DeltaXi
            !
            !-d/d aMajor = 2*(aMinor - MaxImbalance*AMajor)*DeltaXi >0
            !
            M_VV(ConsAMinor_,ConsAMajor_) = 2*(aMinor - MaxImbalance*AMajor)&
               *DeltaXi
         end if
      else
         !
         ! No reflection
         !
         DissipationPlus = - AMinor*AMajor*DeltaXi
         !
         !-dDissipationPlus/d amajor = aMinor*DeltaXi
         !
         M_VV(ConsAMajor_,ConsAMajor_) = 1 + aMinor*DeltaXi
         !
         !-dDissipationPlus/d aminor = aMajor*DeltaXi
         !
         M_VV(ConsAMajor_,ConsAMinor_) = aMajor*DeltaXi

         DissipationMinus = -AMinor*AMajor*DeltaXi
         !
         !-dDissipationMinus /d aMinor = AMajor*DeltaXi
         !
         M_VV(ConsAMinor_,ConsAMinor_) = 1 + AMajor*DeltaXi
         !
         !-dDissipationMinus /d aMajor = aMinor*DeltaXi
         !
         M_VV(ConsAMinor_,ConsAMajor_) = aMinor*DeltaXi
      end if
      ! dissipation_major = (-AMinor*&
      !      (max(0.0,AMajor - MaxImbalance*AMinor)      &
      !      -max(0.0,AMinor - MaxImbalance*AMajor)  )*  &
      !      min(0.5*Reflection/max(AMinor,AMajor), 1.0) &
      !      - AMinor*AMajor)*DeltaXi

      ! dissipation_minor = ( AMajor*&
      !     (max(0.0,AMajor - MaxImbalance*AMinor)      &
      !     -max(0.0,AMinor - MaxImbalance*AMajor)  )*  &
      !     min(0.5*Reflection/max(AMinor,AMajor), 1.0) &
      !     - AMinor*AMajor)*DeltaXi
    end subroutine get_aw_dissipation
    !==========================================================================
    subroutine get_res_heating
      real    :: DeltaXi, AMajor, AMinor, ReflCoef
      integer :: iPoint

      !------------------------------------------------------------------------
      ResHeating_I = 0.0;  Res_VI(ConsAMajor_:ConsAMinor_,:)   = 0
      M_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,:) = 0
      !
      ! Go forward, integrate AMajor_I with given AMinor_I
      !
      L_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,:) = 0
      L_VVI(ConsAMajor_,ConsAMAjor_,1:nPoint) = -1
      Res_VI(ConsAMajor_,2:nPoint) = &
           AMajor_I(1:nPoint-1) - AMajor_I(2:nPoint)
      Res_VI(ConsAMajor_,1) = 0.0
      !
      ! Go backward, integrate AMinor_I with given AMajor_I
      ! We integrate equation,
      !
      ! -2da_-/d\xi=
      != max(1-2a_-/a_+,0)-max(1-2a_+/a_-,0)]* a_+ *
      ! *min(ReflCoef,2max(a_,a_+)) -2a_-a_+
      !
      U_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,:) = 0
      U_VVI(ConsAMinor_,ConsAMinor_,1:nPoint) = -1
      Res_VI(ConsAMinor_,1:nPoint-1) = &
           AMinor_I(2:nPoint) - AMinor_I(1:nPoint-1)
      Res_VI(ConsAMinor_,nPoint) = 0.0
      !
      ! Account for reflection and dissipation:
      !
      do iPoint = 1, nPoint
         AMajor  = AMajor_I( iPoint)
         AMinor  = AMinor_I( iPoint)
         DeltaXi = DXi_I(iPoint)
         ReflCoef = 0.50*(ReflCoef_I(iPoint-1) + ReflCoef_I(iPoint))
         !
         ! Sources and Jacobian
         !
         call get_aw_dissipation(AMajor, AMinor, ReflCoef, DeltaXi, &
              DissipationPlus_I(iPoint), DissipationMinus_I(iPoint),&
              M_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,iPoint))
         Res_VI(ConsAMajor_,iPoint) = Res_VI(ConsAMajor_,iPoint) +  &
              DissipationPlus_I( iPoint)
         Res_VI(ConsAMinor_,iPoint) = Res_VI(ConsAMinor_,iPoint) +  &
              DissipationMinus_I( iPoint)
         ResHeating_I(iPoint) = -2*AMajor*DissipationPlus_I(iPoint) &
              -2*AMinor*DissipationMinus_I(iPoint)
      end do
      !
      !  Particular cases
      !
      Res_VI(ConsAMajor_,1) = 0
      M_VVI(ConsAMajor_,ConsAMajor_:ConsAMinor_,     1) = [1.0, 0.0]
      !
      !
      Res_VI(ConsAMinor_,nPoint) = 0
      M_VVI(ConsAMinor_,ConsAMajor_:ConsAMinor_,nPoint) = [0.0, 1.0]
    end subroutine get_res_heating
    !==========================================================================
    subroutine solve_a_plus_minus(AMinorBC,&
         AMajorBC, nIterIn)
      ! INPUT
      real,            intent(in):: AMinorBC         ! BC for A-
      ! OUTPUT
      real,           intent(out):: AMajorBC          ! BC for A+
      integer,optional,intent(in):: nIterIn
      real:: DeltaXi
      integer::iPoint,iIter
      integer, parameter:: nIterMax = 10
      integer:: nIter
      real   :: AOld, ADiffMax, AP, AM, APMid, AMMid
      character(len=*), parameter:: NameSub = 'solve_a_plus_minus'
      !------------------------------------------------------------------------
      if(UseThomasAlg4Waves)then
         AMajor_I(1) = 1.0
      else
         AMajor_I(0) = 1.0
      end if
      AMinor_I(nPoint)  = AMinorBC
      if(present(nIterIn))then
         nIter=nIterIn
      else
         nIter=nIterMax
      end if
      DissipationMinus_I = 0.0
      DissipationPlus_I  = 0.0
      do iIter=1,nIter
         ADiffMax = 0.0
         if(UseThomasAlg4Waves)then
            call thomas_alg( ADiffMax)
         else
            call runge_kutta(ADiffMax)
         end if
         if(ADiffMax<cTol)EXIT
         if(DoCheckConvHere.and.iIter==nIter)then
            write(*,*)'XiTot=', Xi_I(nPoint),' ADiffMax=', ADiffMax,&
                 ' AMinorBC=',AMinorBC
            write(*,*)'iPoint AMajor Res_VI DCons_VI Error TeSi TiSi PSi'
            do iPoint = 1, nPoint
               write(*,*)iPoint, AMajor_I(iPoint), Res_VI(ConsAMajor_,iPoint)&
                    ,Res_VI(ConsAMajor_,iPoint)-DissipationPlus_I(iPoint),&
                    DissipationPlus_I(iPoint),DCons_VI(ConsAMajor_,iPoint),&
                    TeSi_I(iPoint), TiSi_I(iPoint), PSi_I(iPoint)
            end do
            write(*,*)'iPoint AMinor Res_VI DCons_VI Error ReflCoef VaLog dXi'
            do iPoint = 1, nPoint
               write(*,*)iPoint, AMinor_I(iPoint), Res_VI(ConsAMinor_,iPoint)&
                    ,Res_VI(ConsAMinor_,iPoint)-DissipationMinus_I(iPoint),  &
                    DissipationMinus_I(iPoint), DCons_VI(ConsAMinor_,iPoint),&
                    ReflCoef_I(iPoint), VaLog_I(iPoint), DXi_I(iPoint)
            end do
            call stop_mpi('Did not reach convergence in solve_a_plus_minus')
         end if
      end do
      AMajorBC = AMajor_I(nPoint)
      if(.not.UseThomasAlg4Waves)then
         ResHeating_I = 0.0
         ResHeating_I(1:nPoint-1) = &
              -(AMajor_I(0:nPoint-2) + AMajor_I(1:nPoint-1))*&
              DissipationPlus_I(1:nPoint-1) -&
              (AMinor_I(0:nPoint-2) + AMinor_I(1:nPoint-1))*&
              DissipationMinus_I(1:nPoint-1)
      end if
    end subroutine solve_a_plus_minus
    !==========================================================================
    subroutine thomas_alg(ADiffMax)
      real, intent(inout) :: ADiffMax
      real    :: AOld
      integer :: iPoint
      !------------------------------------------------------------------------
      !
      ! Calculate sources and Jacobians:
      !
      call timing_start('thomas_alg')
      call get_res_heating
      call tridiag_block_matrix2(nI=nPoint,  &
           L_VVI=L_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,&
           1:nPoint),&
           M_VVI=M_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,&
           1:nPoint),&
           U_VVI=U_VVI(ConsAMajor_:ConsAMinor_,ConsAMajor_:ConsAMinor_,&
           1:nPoint),&
           R_VI=Res_VI(ConsAMajor_:ConsAMinor_,1:nPoint),            &
           W_VI=DCons_VI(ConsAMajor_:ConsAMinor_,1:nPoint))
      do iPoint=2, nPoint
         AOld = AMajor_I(iPoint)
         AMajor_I(iPoint) = AMajor_I(iPoint) + DCons_VI(ConsAMajor_,iPoint)
         ADiffMax = max(ADiffMax,abs(DCons_VI(ConsAMajor_,iPoint)))
      end do
      do iPoint = nPoint - 1, 1, -1
         AOld = AMinor_I(iPoint)
         AMinor_I(iPoint) = AMinor_I(iPoint) + DCons_VI(ConsAMinor_,iPoint)
         ADiffMax = max(ADiffMax,abs(DCons_VI(ConsAMinor_,iPoint)))
      end do
      call timing_stop('thomas_alg')
    end subroutine thomas_alg
    !==========================================================================
    subroutine runge_kutta(ADiffMax)
      real, intent(inout) :: ADiffMax
      integer:: iPoint
      real   :: DeltaXi, AP, AM, APMid, AMMid, AOld
      !------------------------------------------------------------------------
      call timing_start('runge_kutta')
      do iPoint=1, nPoint
         ! Predictor
         AP = AMajor_I(iPoint-1); AM = AMinor_I(iPoint-1)
         AOld = AMajor_I(iPoint)
         DeltaXi = DXi_I(iPoint)

         ! Corrector
         AMMid = 0.5*(AMinor_I(iPoint-1) + AMinor_I(iPoint))
         APMid = AP + 0.50*dissipation_major(AP, AM, &
              ReflCoef_I(iPoint-1),DeltaXi)

         DissipationPlus_I(iPoint) = dissipation_major(&
              APMid, AMMid, &
              0.50*(ReflCoef_I(iPoint-1) + ReflCoef_I(iPoint)),DeltaXi)

         AMajor_I(iPoint) = AP + DissipationPlus_I(iPoint)
         ADiffMax = max(ADiffMax, &
              abs(AOld - AMajor_I(iPoint))/max(AOld,AMajor_I(iPoint)))
         ! ADiffMax = max(ADiffMax, abs(AOld - AMajor_I(iPoint)))
      end do
      ! Go backward, integrate AMinor_I with given AMajor_I
      ! We integrate equation,
      !
      ! 2da_-/d\xi=
      !=-[ max(1-2a_-/a_+,0)-max(1-2a_+/a_-,0)]* a_+ *
      ! *min(ReflCoef,2max(a_,a_+))-
      ! -2a_-a_+
      !
      do iPoint = nPoint - 1, 0, -1
         ! Predictor
         AP = AMajor_I(iPoint+1); AM = AMinor_I(iPoint+1)
         AOld = AMinor_I(iPoint)
         DeltaXi = DXi_I(iPoint+1)

         ! Corrector
         APMid = 0.5*(AMajor_I(iPoint+1) + AMajor_I(iPoint))
         AMMid = AM + 0.5*dissipation_minor(AP, AM, &
              ReflCoef_I(iPoint+1),DeltaXi)
         DissipationMinus_I(iPoint+1) = dissipation_minor(&
              APMid, AMMid, &
              0.50*(ReflCoef_I(iPoint+1) + ReflCoef_I(iPoint)),DeltaXi)
         AMinor_I(iPoint) = AMinor_I(iPoint+1) + DissipationMinus_I(iPoint+1)
         ADiffMax = max(ADiffMax,&
              abs(AOld - AMinor_I(iPoint))/max(AOld, AMinor_I(iPoint)))
         ! ADiffMax = max(ADiffMax,abs(AOld - AMinor_I(iPoint)))
      end do
      call timing_stop('runge_kutta')
    end subroutine runge_kutta
    !==========================================================================
    subroutine advance_thread(IsTimeAccurate)
      use ModMain,     ONLY: cfl, Dt, time_accurate
      use ModAdvance,  ONLY: time_BLK, nJ, nK
      use ModPhysics,  ONLY: UnitT_, No2Si_V
      use ModMultiFluid,      ONLY: MassIon_I
      !
      ! Advances the thread solution
      ! If IsTimeAccurate, the solution is advanced through the time
      ! interval, DtLocal. Otherwise, it looks for the steady-state solution
      ! with the advanced boundary condition
      !
      logical, intent(in) :: IsTimeAccurate
      !
      ! Time step in the physical cell from which the thread originates
      !
      real    :: DtLocal,DtInv
      !
      ! Loop variable
      !

      integer :: iPoint, iIter
      !
      ! Enthalpy correction coefficients
      !
      real    :: EnthalpyFlux, FluxConst
      ! real    :: ElectronEnthalpyFlux, IonEnthalpyFlux
      !
      ! Correction accounting for the Enthlpy flux from the TR
      real    :: PressureTRCoef
      !------------------------------------------------------------------------
      if(IsTimeAccurate)then
         if(time_accurate)then
            DtLocal = Dt*No2Si_V(UnitT_)
         else
            DtLocal = cfl*No2Si_V(UnitT_)*&
                 time_BLK(1,max(min(j,nJ),1),max(min(k,nK),1),iBlock)
         end if
         if(DtLocal==0.0)RETURN ! No time-accurate advance is needed
         DtInv = 1/DtLocal
      else
         DtInv = 0.0
      end if
      !
      ! In the equations below:
      !
      !
      ! Initialization
      !
      TeSiStart_I(1:nPoint) = TeSi_I(1:nPoint)
      TiSiStart_I(1:nPoint) = TiSi_I(1:nPoint)
      Cons_I(1:nPoint) = cTwoSevenths*HeatCondParSi*TeSi_I(1:nPoint)**3.50
      SpecHeat_I(1:nPoint-1) = InvGammaMinus1*Z*                     &
           BoundaryThreads_B(iBlock)%DsCellOverBSi_III(1-nPoint:-1,j,k)* &
           PSi_I(1:nPoint-1)/(Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))
      SpecIonHeat_I(1:nPoint-1) = SpecHeat_I(1:nPoint-1)/Z
      ExchangeRate_I(1:nPoint-1) = cExchangeRateSi*InvGammaMinus1*Z**3*&
           BoundaryThreads_B(iBlock)%DsCellOverBSi_III(1-nPoint:-1,j,k)* &
           PSi_I(1:nPoint-1)**2/(&
           (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))**2*&
           TeSi_I(1:nPoint-1)**1.5)
      DeltaEnergy_I= 0.0; Res_VI=0.0 ; ResEnthalpy_I= 0.0
      DeltaIonEnergy_I = 0.0
      PressureTRCoef = 1.0; FluxConst = 0.0
      !
      !
      !
      call solve_heating(nIterIn=nIterHere)
      if(USi>0)then
         FluxConst    = USi * PSi_I(nPoint)/&
              ((Z*TeSiIn + TiSiIn)*PoyntingFluxPerBSi*&
              BoundaryThreads_B(iBlock)% B_III(0,j,k)*No2Si_V(UnitB_))
      elseif(USi<0)then
         FluxConst    = USi * PeSiIn/&
              (TeSiIn*PoyntingFluxPerBSi*&
              BoundaryThreads_B(iBlock)% B_III(0,j,k)*No2Si_V(UnitB_))

      end if
      !
      ! 5/2*U*Pi*(Z+1)
      !
      EnthalpyFlux = FluxConst*(InvGammaMinus1 +1)*(1 + Z)
      !
      ! Calculate flux to TR and its temperature derivative
      !
      call interpolate_lookup_table(iTableTR, TeSi_I(1), Value_V, &
           DoExtrapolate=.false.)

      do iIter = 1,nIterHere
         !
         ! Iterations
         !
         !
         ! Shape the source.
         !
         call get_heat_cond
         !
         ! Add enthalpy correction
         !
         ! Limit particle flux, so that the local speed never exceeds a tenth
         ! of the thermal speed
         Flux_I(1:nPoint)    =sign(min(abs(FluxConst), &
              0.1*sqrt(cBoltzmann*(Z*TeSi_I(1:nPoint) + TiSi_I(1:nPoint))/&
              (MassIon_I(1)*cAtomicMass))*PSi_I(1:nPoint)/&
              ((Z*TeSi_I(1:nPoint) + TiSi_I(1:nPoint))*PoyntingFluxPerBSi*&
              BoundaryThreads_B(iBlock)% B_III(1-nPoint:0,j,k)*No2Si_V(UnitB_))&
              ), FluxConst)
          ! Limit enthalpy flux at the TR:
         if(FluxConst/=0.0)EnthalpyFlux = sign(min(abs(EnthalpyFlux),&
              0.50*HeatFlux2TR/TeSi_I(1)), FluxConst)
         !
         ! Combine the said limitation to limit local enthalpy flux
         !
         EnthalpyFlux_I(1:nPoint) = sign(min(abs(EnthalpyFlux),&
              abs(Flux_I(1:nPoint))*(InvGammaMinus1 +1)*(1 + Z)), FluxConst)
         !
         ! ElectronEnthalpyFlux = EnthalpyFlux*Z/(1 + Z)
         !
         if(USi>0)then
            ResEnthalpy_I(2:nPoint-1) = EnthalpyFlux_I(2:nPoint-1)*Z/(Z +1) &
                 *(TeSi_I(1:nPoint-2) - TeSi_I(2:nPoint-1))
            ResEnthalpy_I(1)   = 0.0
            L_VVI(Cons_,Cons_,2:nPoint-1) =  L_VVI(Cons_,Cons_,2:nPoint-1)&
                 - EnthalpyFlux_I(2:nPoint-1)*Z/(Z +1)*TeSi_I(2:nPoint-1)/&
                 (3.50*Cons_I(2:nPoint-1))
            M_VVI(Cons_,Cons_,2:nPoint-1) =  M_VVI(Cons_,Cons_,2:nPoint-1)&
                 + EnthalpyFlux_I(2:nPoint-1)*Z/(Z +1)*TeSi_I(2:nPoint-1)/&
                 (3.50*Cons_I(2:nPoint-1))
         elseif(USi<0)then
            ResEnthalpy_I(1:nPoint-1) = -EnthalpyFlux_I(1:nPoint-1)*Z/(Z +1)&
                 *(TeSi_I(2:nPoint) - TeSi_I(1:nPoint-1))
            U_VVI(Cons_,Cons_,1:nPoint-1) = U_VVI(Cons_,Cons_,1:nPoint-1)&
                 + EnthalpyFlux_I(1:nPoint-1)*Z/(Z +1)*TeSi_I(1:nPoint-1)/&
                 (3.50*Cons_I(1:nPoint-1))
            M_VVI(Cons_,Cons_,1:nPoint-1) = M_VVI(Cons_,Cons_,1:nPoint-1)&
                 - EnthalpyFlux_I(1:nPoint-1)*Z/(Z +1)*TeSi_I(1:nPoint-1)/&
                 (3.50*Cons_I(1:nPoint-1))
         end if
         !==========Add Gravity Source================================
         !
         ! cGravPot = cGravitation*mSun*cAtomicMass/&
         !   (cBoltzmann*rSun)
         ! GravHydroDyn = cGravPot*MassIon_I(1)/Z
         !
         ! energy flux needed to raise the mass flux rho*u to the
         ! heliocentric distance r equals: rho*u*G*Msun*(1/R_sun -1/r)=
         !=k_B*N_i*M_i(amu)*u*cGravPot*(1-R_sun/r)=
         !=P_e/T_e*cGravPot*(M_ion[amu]/Z)*u*(1/R_sun -1/r)
         !

         ResGravity_I(2:nPoint-1) = 0.5*GravHydroDyn*Flux_I(2:nPoint-1)*(     &
              - BoundaryThreads_B(iBlock)%RInv_III(1-nPoint:-2,j,k)  &
              + BoundaryThreads_B(iBlock)%RInv_III(3-nPoint: 0,j,k))
         ResGravity_I(1)          = 0.5*GravHydroDyn*Flux_I(1)*(     &
              - BoundaryThreads_B(iBlock)%RInv_III(1-nPoint,j,k)     &
              + BoundaryThreads_B(iBlock)%RInv_III(2-nPoint,j,k))
         ResEnthalpy_I(1:nPoint-1) = ResEnthalpy_I(1:nPoint-1) + &
              0.5*ResGravity_I(1:nPoint-1)

         !
         ! For the time accurate mode, account for the time derivative
         ! The contribution to the Jacobian be modified although the specific
         ! heat should not,  because the conservative variable is
         ! flux-by-length, not the temperature
         !
         M_VVI(Cons_,Cons_,1:nPoint-1) = M_VVI(Cons_,Cons_,1:nPoint-1) + &
              DtInv*SpecHeat_I(1:nPoint-1)*TeSi_I(1:nPoint-1)/   &
              (3.50*Cons_I(1:nPoint-1))
         M_VVI(Ti_,Ti_,1:nPoint-1) = M_VVI(Ti_,Ti_,1:nPoint-1) + &
              DtInv*SpecIonHeat_I(1:nPoint-1)
         PressureTRCoef = sqrt(max(&
              1 - EnthalpyFlux*TeSi_I(1)/HeatFlux2TR,1.0e-8))
         Res_VI(Cons_,1:nPoint-1) = -DeltaEnergy_I(1:nPoint-1) +      &
              ResHeating_I(1:nPoint-1)*QeRatio +  ResCooling_I(1:nPoint-1) +&
              ResEnthalpy_I(1:nPoint-1) + ResHeatCond_I(1:nPoint-1) +&
              ExchangeRate_I(1:nPoint-1)*&
              (TiSi_I(1:nPoint-1) - TeSi_I(1:nPoint-1))
         M_VVI(Cons_,Ti_,1:nPoint-1) = M_VVI(Cons_,Ti_,1:nPoint-1) -&
               ExchangeRate_I(1:nPoint-1)
         M_VVI(Cons_,Cons_,1:nPoint-1) = M_VVI(Cons_,Cons_,1:nPoint-1) +&
               ExchangeRate_I(1:nPoint-1)*TeSi_I(1:nPoint-1)/&
               (3.50*Cons_I(1:nPoint-1))
         ! M_VVI(Cons_,LogP_,1:nPoint-1) = M_VVI(Cons_,LogP_,1:nPoint-1)&
         !  -0.250*QeRatio*ResHeating_I(1:nPoint-1) !=-dHeating/dLogPe
         ! M_VVI(Cons_,Cons_,1:nPoint-1) = M_VVI(Cons_,Cons_,1:nPoint-1) + &
         !     0.250*QeRatio*ResHeating_I(1:nPoint-1)/&
         !     (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))*Z*&
         !     TeSi_I(1:nPoint-1)/(3.50*Cons_I(1:nPoint-1))!=-dHeating/dCons
         ! M_VVI(Cons_,Ti_,1:nPoint-1) = M_VVI(Cons_,Ti_,1:nPoint-1) + &
         !     0.250*QeRatio*ResHeating_I(1:nPoint-1)/&
         !     (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1)) !=-dHeating/d log Ti
         DCons_VI = 0.0
         ! IonEnthalpyFlux = ElectronEnthalpyFlux/Z
         ResEnthalpy_I=0.0
         if(USi>0)then
            ResEnthalpy_I(2:nPoint-1) = EnthalpyFlux_I(2:nPoint-1)/(Z +1) &
                 *(TiSi_I(1:nPoint-2) - TiSi_I(2:nPoint-1))
            ResEnthalpy_I(1)   = 0.0
            L_VVI(Ti_,Ti_,2:nPoint-1) =  L_VVI(Ti_,Ti_,2:nPoint-1)&
                 - EnthalpyFlux_I(2:nPoint-1)/(Z +1)
            M_VVI(Ti_,Ti_,2:nPoint-1) =  M_VVI(Ti_,Ti_,2:nPoint-1)&
                 + EnthalpyFlux_I(2:nPoint-1)/(Z +1)
         elseif(USi<0)then
            ResEnthalpy_I(1:nPoint-1) = -EnthalpyFlux_I(1:nPoint-1)/(Z +1)&
                 *(TiSi_I(2:nPoint) - TiSi_I(1:nPoint-1))
            U_VVI(Ti_,Ti_,1:nPoint-1) = U_VVI(Ti_,Ti_,1:nPoint-1)&
                 + EnthalpyFlux_I(1:nPoint-1)/(Z +1)
            M_VVI(Ti_,Ti_,1:nPoint-1) = M_VVI(Ti_,Ti_,1:nPoint-1)&
                 - EnthalpyFlux_I(1:nPoint-1)/(Z +1)
         end if
         ResEnthalpy_I(1:nPoint-1) = ResEnthalpy_I(1:nPoint-1) + &
              0.5*ResGravity_I(1:nPoint-1)
         Res_VI(Ti_,1:nPoint-1) = -DeltaIonEnergy_I(1:nPoint-1) +      &
              ResHeating_I(1:nPoint-1)*(1-QeRatio) + ResEnthalpy_I(1:nPoint-1)&
              + ExchangeRate_I(1:nPoint-1)*&
              (TeSi_I(1:nPoint-1) - TiSi_I(1:nPoint-1))
         M_VVI(Ti_,Ti_,1:nPoint-1) = M_VVI(Ti_,Ti_,1:nPoint-1) +&
               ExchangeRate_I(1:nPoint-1)
         M_VVI(Ti_,Cons_,1:nPoint-1) = M_VVI(Ti_,Cons_,1:nPoint-1) -&
               ExchangeRate_I(1:nPoint-1)*TeSi_I(1:nPoint-1)/&
               (3.50*Cons_I(1:nPoint-1))
         ! M_VVI(Ti_,LogP_,1:nPoint-1) = M_VVI(Ti_,LogP_,1:nPoint-1)&
         !  -0.250*(1 - QeRatio)*ResHeating_I(1:nPoint-1) !=-dHeating/dLogPe
         ! M_VVI(Ti_,Cons_,1:nPoint-1) = M_VVI(Ti_,Cons_,1:nPoint-1) + &
         !     0.250*(1 - QeRatio)*ResHeating_I(1:nPoint-1)/&
         !     (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))*Z*&
         !     TeSi_I(1:nPoint-1)/(3.50*Cons_I(1:nPoint-1))!=-dHeating/dCons
         ! M_VVI(Ti_,Ti_,1:nPoint-1) = M_VVI(Ti_,Ti_,1:nPoint-1) + &
         !     0.250*(1 - QeRatio)*ResHeating_I(1:nPoint-1)/&
         !     (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1)) !=-dHeating/d log Ti
         call tridiag_block_matrix3(nI=nPoint-1,     &
              L_VVI=L_VVI(  Cons_:LogP_,Cons_:LogP_,1:nPoint-1),&
              M_VVI=M_VVI(  Cons_:LogP_,Cons_:LogP_,1:nPoint-1),&
              U_VVI=U_VVI(  Cons_:LogP_,Cons_:LogP_,1:nPoint-1),&
              R_VI=Res_VI(  Cons_:LogP_,            1:nPoint-1),&
              W_VI=DCons_VI(Cons_:LogP_,            1:nPoint-1))
         !
         ! limit DeltaCons
         !
         DCons_VI(Cons_,1:nPoint-1) = max(min(DCons_VI(Cons_, 1:nPoint-1), &
              ConsMax - Cons_I(    1:nPoint-1),        Cons_I(1:nPoint-1)),&
              ConsMin - Cons_I(    1:nPoint-1),   -0.5*Cons_I(1:nPoint-1))
         DCons_VI(Ti_,1:nPoint-1) = max(min(DCons_VI(Ti_, 1:nPoint-1), &
              TeSiMax - TiSi_I(    1:nPoint-1),        TiSi_I(1:nPoint-1)),&
              TeSiMin - TiSi_I(    1:nPoint-1),   -0.5*TiSi_I(1:nPoint-1))
         !
         ! Apply DeltaCons
         !
         Cons_I(1:nPoint-1) = Cons_I(1:nPoint-1) + DCons_VI(Cons_,1:nPoint-1)
         !
         ! Recover temperature
         !
         TeSi_I(1:nPoint-1) = &
              (3.50*Cons_I(1:nPoint-1)/HeatCondParSi)**cTwoSevenths
         TiSi_I(1:nPoint-1) = TiSi_I(1:nPoint-1) + DCons_VI(Ti_,1:nPoint-1)
         !
         ! Eliminate jump in ion temperature, to avoid an unphysical
         ! jump in the alfven speed resulting in peak reflection
         !
         if(FluxConst>0.0)TiSi_I(nPoint) = TiSi_I(nPoint-1)
         !
         ! Change in the internal energy (to correct the energy source
         ! for the time-accurate mode):
         !
         DeltaEnergy_I(1:nPoint-1) = DtInv*SpecHeat_I(1:nPoint-1)* &
              (TeSi_I(1:nPoint-1) - TeSiStart_I(1:nPoint-1))
         DeltaIonEnergy_I(1:nPoint-1) = DtInv*SpecIonHeat_I(1:nPoint-1)* &
              (TiSi_I(1:nPoint-1) - TiSiStart_I(1:nPoint-1))
         !
         ! Calculate TR pressure
         ! For next iteration calculate TR heat flux and
         ! its temperature derivative
         !
         call interpolate_lookup_table(iTableTR, TeSi_I(1), Value_V, &
              DoExtrapolate=.false.)
         !
         ! Set pressure for updated temperature
         !
         Value_V(LengthPAvrSi_) = Value_V(LengthPAvrSi_)*PressureTRCoef
         call set_pressure
         call solve_heating(nIterIn=nIterHere)
         ExchangeRate_I(1:nPoint-1) = cExchangeRateSi*InvGammaMinus1*Z**3*&
              BoundaryThreads_B(iBlock)%DsCellOverBSi_III(1-nPoint:-1,j,k)* &
              PSi_I(1:nPoint-1)**2/(&
              (Z*TeSi_I(1:nPoint-1) + TiSi_I(1:nPoint-1))**2*&
              TeSi_I(1:nPoint-1)**1.5)
         if(all(abs(DCons_VI(Cons_,1:nPoint-1))<cTol*Cons_I(1:nPoint-1)))EXIT
      end do
      if(any(abs(DCons_VI(Cons_,1:nPoint-1))>cTol*Cons_I(1:nPoint-1))&
           .and.DoCheckConvHere)then
         write(*,'(a)')'Te TeMin PSi_I Heating Enthalpy'
         do iPoint=1,nPoint
            write(*,'(i4,6es15.6)')iPoint, TeSi_I(iPoint),&
                 BoundaryThreads_B(iBlock)%TGrav_III(iPoint-nPoint,j,k),&
                 PSi_I(iPoint),ResHeating_I(iPoint), ResEnthalpy_I(iPoint)
         end do
         write(*,'(a,es15.6,a,3es15.6)')'Error =',maxval(&
              abs(DCons_VI(Cons_,1:nPoint-1)/Cons_I(1:nPoint-1))),&
              ' at the point Xyz=',Xyz_DGB(:,1,j,k,iBlock)
         write(*,'(a,5es15.6)')&
              'Input parameters: TeSiIn,USiIn,USi,PeSiIn,PCoef=',&
              TeSiIn,USiIn,USi,PeSiIn,PressureTRCoef
         call stop_mpi('Algorithm failure in advance_thread')
      end if
    end subroutine advance_thread
    !==========================================================================

  end subroutine solve_boundary_thread
  !============================================================================
  ! This routine solves three-diagonal system of equations:                    !
  !  ||m_1 u_1  0....        || ||w_1|| ||r_1||                                !
  !  ||l_2 m_2 u_2...        || ||w_2|| ||r_2||                                !
  !  || 0  l_3 m_3 u_3       ||.||w_3||=||r_3||                                !
  !  ||...                   || ||...|| ||...||                                !
  !  ||.............0 l_n m_n|| ||w_n|| ||r_n||                                !
  ! Prototype: Numerical Recipes, Chapter 2.6, p.40.
  ! Here each of the compenets w_i and r_i are nDim-component states and
  ! m_i, l_i, u_i are nDim*nDim matrices                                       !
  subroutine tridiag_block_matrix3(nI,L_VVI,M_VVI,U_VVI,R_VI,W_VI)
    integer, parameter:: nDim = 3
    integer, intent(in):: nI
    real, intent(in)   :: L_VVI(nDim,nDim,nI)
    real, intent(in)   :: M_VVI(nDim,nDim,nI)
    real, intent(in)   :: U_VVI(nDim,nDim,nI)
    real, intent(in)   :: R_VI(nDim,nI)
    real, intent(out)  :: W_VI(nDim,nI)

    integer:: j
    real   :: TildeM_VV(nDim,nDim), TildeMInv_VV(nDim,nDim)
    real   :: TildeMInvDotU_VVI(nDim,nDim,2:nI)

    ! If tilde(M)+L.Inverted(\tilde(M))\dot.U = M, then the equation
    !      (M+L+U)W = R
    ! may be equivalently written as
    ! (tilde(M) +L).(I + Inverted(\tilde(M)).U).W=R

    character(len=*), parameter :: NameTiming = 'tridiag3'
    character(len=*), parameter:: NameSub = 'tridiag_block_matrix3'
    !--------------------------------------------------------------------------
    call timing_start(NameTiming)
    if (determinant(M_VVI(:,:,1)) == 0.0) then
       call stop_mpi('Error in tridiag: M_I(1)=0')
    end if
    TildeM_VV = M_VVI(:,:,1)
    TildeMInv_VV = inverse_matrix(TildeM_VV,DoIgnoreSingular=.true.)

    ! First 3-vector element of the vector, Inverted(tilde(M) + L).R
    W_VI(:,1) = matmul(TildeMInv_VV,R_VI(:,1))
    do j=2, nI
       ! Next 3*3 blok element of the matrix, Inverted(Tilde(M)).U
       TildeMInvDotU_VVI(:,:,j) = matmul(TildeMInv_VV,U_VVI(:,:,j-1))
       ! Next 3*3 block element of matrix tilde(M), obeying the eq.
       ! tilde(M)+L.Inverted(\tilde(M))\dot.U = M
       TildeM_VV = M_VVI(:,:,j) - &
            matmul(L_VVI(:,:,j),TildeMInvDotU_VVI(:,:,j))
       if (determinant(TildeM_VV) == 0.0) then
          write(*,*)'j, M_I(j), L_I(j), TildeMInvDotU_I(j) = ',j, &
               M_VVI(:,:,j),L_VVI(:,:,j),TildeMInvDotU_VVI(:,:,j)
          call stop_mpi('3*3 block Tridiag failed')
       end if
       ! Next element of inverted(Tilde(M))
       TildeMInv_VV = inverse_matrix(TildeM_VV,DoIgnoreSingular=.true.)
       ! Next 2-vector element of the vector, Inverted(tilde(M) + L).R
       ! satisfying the eq. (tilde(M) + L).W = R
       W_VI(:,j) = matmul(TildeMInv_VV,R_VI(:,j) - &
            matmul(L_VVI(:,:,j),W_VI(:,j-1)))
    end do
    do j = nI - 1, 1, -1
       ! Finally we solve equation
       ! (I + Inverted(Tilde(M)).U).W =  Inverted(tilde(M) + L).R
       W_VI(:,j) = W_VI(:,j)-matmul(TildeMInvDotU_VVI(:,:,j+1),W_VI(:,j+1))
    end do
    call timing_stop(NameTiming)
  end subroutine tridiag_block_matrix3
  !============================================================================
  subroutine tridiag_block_matrix2(nI,L_VVI,M_VVI,U_VVI,R_VI,W_VI)
    integer, parameter:: nDim = 2
    integer, intent(in):: nI
    real, intent(in)   :: L_VVI(nDim,nDim,nI)
    real, intent(in)   :: M_VVI(nDim,nDim,nI)
    real, intent(in)   :: U_VVI(nDim,nDim,nI)
    real, intent(in)   :: R_VI(nDim,nI)
    real, intent(out)  :: W_VI(nDim,nI)

    integer:: j
    real   :: TildeM_VV(nDim,nDim), TildeMInv_VV(nDim,nDim)
    real   :: TildeMInvDotU_VVI(nDim,nDim,2:nI)

    ! If tilde(M)+L.Inverted(\tilde(M))\dot.U = M, then the equation
    !      (M+L+U)W = R
    ! may be equivalently written as
    ! (tilde(M) +L).(I + Inverted(\tilde(M)).U).W=R
    character(len=*), parameter :: NameTiming = 'tridiag2'
    character(len=*), parameter:: NameSub = 'tridiag_block_matrix2'
    !--------------------------------------------------------------------------
    call timing_start(NameTiming)
    if (determinant_2(M_VVI(:,:,1)) == 0.0) then
       call stop_mpi('Error in tridiag: M_I(1)=0')
    end if
    TildeM_VV = M_VVI(:,:,1)
    TildeMInv_VV = inverse_matrix_2(TildeM_VV)
    ! First 3-vector element of the vector, Inverted(tilde(M) + L).R
    W_VI(:,1) = matmul(TildeMInv_VV,R_VI(:,1))
    do j=2, nI
       ! Next 3*3 blok element of the matrix, Inverted(Tilde(M)).U
       TildeMInvDotU_VVI(:,:,j) = matmul(TildeMInv_VV,U_VVI(:,:,j-1))
       ! Next 3*3 block element of matrix tilde(M), obeying the eq.
       ! tilde(M)+L.Inverted(\tilde(M))\dot.U = M
       TildeM_VV = M_VVI(:,:,j) - &
            matmul(L_VVI(:,:,j),TildeMInvDotU_VVI(:,:,j))
       if (determinant_2(TildeM_VV) == 0.0) then
          write(*,*)'j, M_I(j), L_I(j), TildeMInvDotU_I(j) = ',j, &
               M_VVI(:,:,j),L_VVI(:,:,j),TildeMInvDotU_VVI(:,:,j)
          call stop_mpi('2*2 block Tridiag failed')
       end if
       ! Next element of inverted(Tilde(M))
       TildeMInv_VV = inverse_matrix_2(TildeM_VV)
       ! Next 2-vector element of the vector, Inverted(tilde(M) + L).R
       ! satisfying the eq. (tilde(M) + L).W = R
       ! W_VI(:,j) = matmul(TildeMInv_VV,R_VI(:,j)) - &
       !     matmul(TildeMInv_VV,matmul(L_VVI(:,:,j),W_VI(:,j-1)))
       W_VI(:,j) = matmul(TildeMInv_VV,R_VI(:,j) - &
            matmul(L_VVI(:,:,j),W_VI(:,j-1)))
    end do
    do j = nI - 1, 1, -1
       ! Finally we solve equation
       ! (I + Inverted(Tilde(M)).U).W =  Inverted(tilde(M) + L).R
       W_VI(:,j) = W_VI(:,j)-matmul(TildeMInvDotU_VVI(:,:,j+1),W_VI(:,j+1))
    end do
    call timing_stop(NameTiming)
  end subroutine tridiag_block_matrix2
  !============================================================================
  real function determinant_2(a_II)
    real, intent(in) :: a_II(2,2)
    !--------------------------------------------------------------------------
    determinant_2 = a_II(1,1)*a_II(2,2) - a_II(1,2)*a_II(2,1)
  end function determinant_2
  !============================================================================
  function inverse_matrix_2(a_II) result(b_II)
    real :: b_II(2,2)
    real, intent(in) :: a_II(2,2)

    !--------------------------------------------------------------------------
    b_II(1,1) =  a_II(2,2); b_II(2,2) =  a_II(1,1)
    b_II(1,2) = -a_II(1,2); b_II(2,1) = -a_II(2,1)
    b_II = b_II/determinant_2(a_II)
  end function inverse_matrix_2
  !============================================================================
  subroutine set_field_line_thread_bc(nGhost, iBlock, nVarState, State_VG, &
               iImplBlock)

    use EEE_ModCommonVariables, ONLY: UseCme
    use EEE_ModMain,            ONLY: EEE_get_state_BC
    use ModMain,       ONLY: n_step, iteration_number, time_simulation
    use ModAdvance,      ONLY: State_VGB
    use BATL_lib, ONLY:  MinI, MaxI, MinJ, MaxJ, MinK, MaxK, nJ, nK
    use BATL_size, ONLY:  nJ, nK
    use ModPhysics,      ONLY: No2Si_V, Si2No_V, UnitTemperature_, &
         UnitEnergyDens_, UnitU_, UnitX_, UnitB_, InvGammaElectronMinus1
    use ModVarIndexes,   ONLY: Rho_, p_, Bx_, Bz_, &
         RhoUx_, RhoUz_, EHot_
    use ModImplicit,     ONLY: iTeImpl
    use ModB0,           ONLY: B0_DGB
    use ModWaves,        ONLY: WaveFirst_, WaveLast_
    use ModHeatFluxCollisionless, ONLY: UseHeatFluxCollisionless, &
         get_gamma_collisionless
    use ModFieldLineThread, ONLY: DoPlotThreads
    integer, intent(in):: nGhost
    integer, intent(in):: iBlock
    integer, intent(in):: nVarState
    real, intent(inout):: State_VG(nVarState,MinI:MaxI,MinJ:MaxJ,MinK:MaxK)

    ! Optional arguments when called by semi-implicit scheme
    integer, optional, intent(in):: iImplBlock
    ! Determines, which action should be done with the thread
    ! before setting the BC
    integer:: iAction

    integer :: i, j, k, Major_, Minor_, kStart, kEnd, jStart, jEnd
    real :: TeSi, PeSi, BDirThread_D(3), BDirFace_D(3)! BDir_D(3),
    real :: U_D(3), U, B1_D(3), SqrtRho, DirR_D(3)
    real :: PeSiOut, AMinor, AMajor, DTeOverDsSi, DTeOverDs, GammaHere
    real :: TiSiIn, PiSiOut
    real :: RhoNoDimOut, UAbsMax
    ! CME parameters, if needed
    real:: RhoCme, Ucme_D(3), Bcme_D(3), pCme

    character(len=*), parameter:: NameSub = 'set_field_line_thread_bc'
    !--------------------------------------------------------------------------
    if(present(iImplBlock))then
       if(BoundaryThreads_B(iBlock)%iAction/=Done_)&
            call stop_mpi('Algorithm error in '//NameSub)
       iAction=Impl_
    else
       iAction=BoundaryThreads_B(iBlock)%iAction
    end if
    if(iAction==Done_)RETURN

    call timing_start('set_thread_bc')
    ! Start from floating boundary values
    do k = MinK, MaxK; do j = MinJ, maxJ; do i = 1 - nGhost, 0
       State_VG(:, i,j,k) = State_VG(:,1, j, k)
    end do; end do; end do
    if((.not.DoPlotTHreads).or.UseTriangulation)then
       ! In this case only the threads originating from
       ! the physical cells are needed
       kStart =  1; jStart =  1
       kEnd   = nK; jEnd   = nJ
    else
       ! For graphic we need threads originating from
       ! both physical cells and from one layer of ghost
       ! cells in j- and k- direction
       kStart = kThreadMin
       kEnd   = kThreadMax
       jStart = jThreadMin
       jEnd   = jThreadMax
    end if

    ! Fill in the temperature array
    if(UseIdealEos)then
       do k = kStart, kEnd; do j = jStart, jEnd
          Te_G(0:1,j,k) = TeFraction*State_VGB(iP,1,j,k,iBlock) &
               /State_VGB(Rho_,1,j,k,iBlock)
       end do; end do
    else
       call stop_mpi('Generic EOS is not applicable with threads')
    end if
    do k = kStart, kEnd; do j = jStart, jEnd
       !
       ! Field on thread is nothing but B0_field. On top of thread
       ! there is the cell-centered B0:
       !
       BDirThread_D = B0_DGB(:, 1, j, k, iBlock)
       !
       ! On the other hand, the heat flux through the inner bopundary, which
       ! needs to be set via the bondary condition is epressed in terms of
       ! the face-averaged field:
       !
       B1_D = State_VGB(Bx_:Bz_,1,j,k,iBlock)
       BDirFace_D = B1_D + 0.50*(BDirThread_D + &
            B0_DGB(:, 0, j, k, iBlock))
       BDirFace_D = BDirFace_D/max(norm2(BDirFace_D), 1e-30)

       if(UseCME)then
          !
          ! Thread field may include a contribution from CME
          !
          !
          call EEE_get_state_BC(Xyz_DGB(:,1,j,k,iBlock), &
               RhoCme, Ucme_D, Bcme_D, pCme, &
               time_simulation, n_step, iteration_number)
          BDirThread_D = BDirThread_D + Bcme_D*Si2No_V(UnitB_)
       end if
       BDirThread_D = BDirThread_D/max(norm2(BDirThread_D), 1e-30)

       DirR_D = Xyz_DGB(:,1,j,k,iBlock)
       DirR_D = DirR_D/norm2(DirR_D)

       if(sum(BDirThread_D*DirR_D) <  0.0)then
          BDirThread_D = -BDirThread_D
          Major_ = WaveLast_
          Minor_ = WaveFirst_
       else
          Major_ = WaveFirst_
          Minor_ = WaveLast_
       end if
       if(sum(BDirFace_D*DirR_D) <  0.0)&
            BDirFace_D = -BDirFace_D
       ! Calculate input parameters for solving the thread
       Te_G(0, j, k) = max(TeMin,min(Te_G(0, j, k), &
            BoundaryThreads_B(iBlock) % TMax_II(j,k)))
       UAbsMax = 0.10*sqrt(Te_G(0,j,k))
       TeSi = Te_G(0, j, k)*No2Si_V(UnitTemperature_)
       SqrtRho = sqrt(State_VGB(Rho_, 1, j, k, iBlock))
       AMinor = min(1.0,&
            sqrt(  State_VGB(Minor_, 1, j, k, iBlock)/&
            (SqrtRho* PoyntingFluxPerB)  ))
       U_D = State_VGB(RhoUx_:RhoUz_, 1, j, k, iBlock)/&
            State_VGB(Rho_, 1, j, k, iBlock)
       U = sum(U_D*BDirThread_D)
       U = sign(min(abs(U), UAbsMax), U)

       PeSi = PeFraction*State_VGB(iP, 1, j, k, iBlock)&
            *(Te_G(0,j,k)/Te_G(1,j,k))*No2Si_V(UnitEnergyDens_)
       TiSiIn = TiFraction*State_VGB(p_,1,j,k,iBlock) &
               /State_VGB(Rho_,1,j,k,iBlock)*No2Si_V(UnitTemperature_)
       call solve_boundary_thread(j=j, k=k, iBlock=iBlock, iAction=iAction,    &
            TeSiIn=TeSi, TiSiIn=TiSiIn, PeSiIn=PeSi, USiIn=U*No2Si_V(UnitU_),  &
            AMinorIn=AMinor,DTeOverDsSiOut=DTeOverDsSi, &
            PeSiOut=PeSiOut, PiSiOut = PiSiOut, &
            RhoNoDimOut=RhoNoDimOut, AMajorOut=AMajor)
       if(present(iImplBlock))then
          DTeOverDs = DTeOverDsSi * Si2No_V(UnitTemperature_)/Si2No_V(UnitX_)
          ! Solve equation: -(TeGhost-TeTrue)/DeltaR =
          ! dTe/ds*(b . DirR)
          Te_G(0, j, k) = Te_G(0, j, k) - DTeOverDs/max(&
               sum(BDirFace_D*DirR_D),0.7)*&
               BoundaryThreads_B(iBlock)% DeltaR_II(j,k)
          ! Version Easter 2015 Limit TeGhost
          Te_G(0, j, k) = max(TeMin,min(Te_G(0, j, k), &
               BoundaryThreads_B(iBlock) % TMax_II(j,k)))
          State_VG(iTeImpl, 0, j, k) = Te_G(0, j, k)
          CYCLE
       end if

       State_VG(iP,0,j,k) = PeSiOut*Si2No_V(UnitEnergyDens_)/PeFraction
       ! Extrapolation of pressure
       State_VG(iP, 1-nGhost:-1, j, k) = State_VG(iP,0,j,k)**2/&
            State_VG(iP,1,j,k)
       ! Assign ion pressure (if separate from electron one)
       if(iP/=p_)then
          State_VG(p_, 0, j, k) = PiSiOut*Si2No_V(UnitEnergyDens_)
          State_VG(p_,1-nGhost:-1,j,k) = State_VG(p_,0,j,k)**2/&
            State_VG(p_,1,j,k)
       end if

       State_VG(Rho_, 0, j, k) = RhoNoDimOut
       UAbsMax = min(UAbsMax,0.10*sqrt(State_VG(p_, 0, j, k)/RhoNoDimOut))
       ! Extrapolation of density
       State_VG(Rho_, 1-nGhost:-1, j, k) = State_VG(Rho_, 0, j, k)**2&
            /State_VG(Rho_,1,j,k)

       do i = 1-nGhost, 0
          ! Ghost cell value of the magnetic field: cancel radial B1 field
          B1_D = State_VG(Bx_:Bz_, 1-i, j, k)
          State_VG(Bx_:Bz_, i, j, k) = B1_D - DirR_D*sum(DirR_D*B1_D)
          if(UseCME)then
             ! Maintain the normal component of the superimposed
             ! CME magnetic configuration
             call EEE_get_state_BC(Xyz_DGB(:,i,j,k,iBlock), &
                  RhoCme, Ucme_D, Bcme_D, pCme, &
                  time_simulation, n_step, iteration_number)
             Bcme_D = Bcme_D*Si2No_V(UnitB_)
             State_VG(Bx_:Bz_, i, j, k) = &
                  State_VG(Bx_:Bz_, i, j, k) + DirR_D*sum(DirR_D*Bcme_D)
          end if
          ! Gnost cell value of velocity: keep the velocity projection
          ! onto the magnetic field, if UseAlignedVelocity=.true.
          ! Reflect the other components
          U_D = State_VG(RhoUx_:RhoUz_,1-i,j,k)/State_VG(Rho_,1-i,j,k)
          if(UseAlignedVelocity)then
             U   = sum(U_D*BDirThread_D); U_D = U_D - U*BDirThread_D
             U   = sign(min(abs(U), UAbsMax), U)
          else
             U = 0
          end if
          State_VG(RhoUx_:RhoUz_, i, j, k) = -U_D*State_VG(Rho_,i,j,k) &
                + U*BDirThread_D*State_VG(Rho_,i,j,k)

          State_VG(Major_, i, j, k) = AMajor**2 * PoyntingFluxPerB *&
               sqrt( State_VG(Rho_, i, j, k) )
       end do

       if(Ehot_ > 1)then
          if(UseHeatFluxCollisionless)then
             call get_gamma_collisionless(Xyz_DGB(:,1,j,k,iBlock), GammaHere)
             State_VG(Ehot_,1-nGhost:0,j,k) = &
                  State_VG(iP,1-nGhost:0,j,k)*&
                  (1.0/(GammaHere - 1) - InvGammaElectronMinus1)
          else
             State_VG(Ehot_,1-nGhost:0,j,k) = 0.0
          end if
       end if
    end do; end do
    BoundaryThreads_B(iBlock)%iAction = Done_

    call timing_stop('set_thread_bc')
  end subroutine set_field_line_thread_bc
  !============================================================================
end module ModThreadedLC
!==============================================================================
