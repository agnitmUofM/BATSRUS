!^CFG COPYRIGHT UM
!^CFG FILE IMPLICIT
!============================================================================
module ModMultiGroupDiffusion

  use ModVarIndexes, ONLY: p_
  use ModProcMH, ONLY: iProc
  !use ModMain, ONLY: iTest, jTest, kTest, BlkTest


  implicit none
  save

  ! This module is needed for the multigroup diffusion approximation for
  ! radiation-hydrodynamics.

  private !except

  ! Public methods
  public :: init_rad_diffusion
  public :: get_rad_energy_flux
  public :: calc_source_rad_diffusion
  public :: set_rad_outflow_bc
  public :: get_impl_rad_diff_state
  public :: get_rad_diffusion_rhs
  public :: add_jacobian_rad_diff
  public :: update_impl_rad_diff

  ! Logical for adding multigroup diffusion
  logical, public :: IsNewBlockRadDiffusion = .true.
  logical, public :: IsNewTimestepRadDiffusion = .true.

  ! Coefficients for two-temperature electron-radiation model
  real, allocatable :: DiffCoef_VFDB(:,:,:,:,:,:)
  real, allocatable :: RelaxCoef_VCB(:,:,:,:,:)
  real, allocatable :: DiffSemiCoef_VGB(:,:,:,:,:)
  real, allocatable :: PointSemiCoef_VCB(:,:,:,:,:)

  ! Index which vars involve diffusion
  integer, allocatable :: iDiff_I(:)
  integer :: nDiff

  ! Number of relaxation coefficients
  integer, allocatable :: iRelax_I(:)
  integer :: nRelax

  ! Number of point implicit coefficients
  integer :: nPoint
  ! Index which variable involve point implicit calculation
  integer :: iPoint
  ! Named indices for point implicit coefficients
  integer, parameter :: Relax_ = 1, Planck_ = 2

  ! radiation energy used for calculating radiative energy flux
  real, allocatable :: Erad_G(:,:,:)
  ! temporary radiation energy array needed by set_block_field
  real, allocatable :: Erad1_G(:,:,:)

  real, parameter :: GammaRel = 4.0/3.0

  real :: EradMin

contains

  !============================================================================

  subroutine init_rad_diffusion

    use ModAdvance,     ONLY: Erad_
    use ModMain,        ONLY: UseRadDiffusion
    use ModSize,        ONLY: nI, nJ, nK, MaxBlock, nDim
    use ModVarIndexes,  ONLY: NameVar_V
    use ModImplicit,    ONLY: UseSemiImplicit, UseFullImplicit, &
         TypeSemiImplicit, iEradImpl, iTeImpl
    use ModPhysics,     ONLY: Si2No_V, UnitTemperature_, cRadiationNo
    use ModTemperature, ONLY: TradMinSi

    character(len=*), parameter :: NameSub = "init_rad_diffusion"
    !------------------------------------------------------------------------

    if(allocated(Erad_G)) RETURN

    ! Make sure that Erad_ is correct
    if(UseRadDiffusion)then
       if(NameVar_V(Erad_) /= "Erad") call stop_mpi(NameSub// &
            ": incorrect index for Erad variable in ModEquation")

       EradMin = cRadiationNo*(TradMinSi*Si2No_V(UnitTemperature_))**4
    end if

    allocate(Erad_G(-1:nI+2,-1:nJ+2,-1:nK+2))
    if(UseSemiImplicit) allocate(Erad1_G(0:nI+1,0:nJ+1,0:nK+1))

    if(UseFullImplicit)then
       nDiff = 1
       allocate(iDiff_I(nDiff))
       iDiff_I(1) = Erad_
       nRelax = 1
    end if
       
    if(UseSemiImplicit)then

       select case(TypeSemiImplicit)
       case('radiation')
          iEradImpl = 1
          nDiff = 1
          allocate(iDiff_I(nDiff))
          iDiff_I(1) = iEradImpl
          nRelax = 0
          nPoint = 2
          iPoint = iEradImpl
       case('radcond')
          iTeImpl = 1; iEradImpl = 2
          nDiff = 2
          allocate(iDiff_I(nDiff))
          iDiff_I = (/ iTeImpl, iEradImpl /)
          nRelax = 1
          allocate(iRelax_I(nRelax))
          iRelax_I(1) = iEradImpl
          nPoint = 0
       case('cond')
          iTeImpl = 1
          nDiff = 1
          allocate(iDiff_I(nDiff))
          iDiff_I(1) = iTeImpl
          nRelax = 0
          nPoint = 0
       end select

       if(nPoint>0)then
          allocate(PointSemiCoef_VCB(nPoint,nI,nJ,nK,MaxBlock))
          PointSemiCoef_VCB = 0.0
       end if

       allocate(DiffSemiCoef_VGB(nDiff,-1:nI+2,-1:nJ+2,-1:nK+2,MaxBlock))
       DiffSemiCoef_VGB = 0.0
    end if

    if(nRelax>0)then
       allocate(RelaxCoef_VCB(nRelax,nI,nJ,nK,MaxBlock))
       RelaxCoef_VCB = 0.0
    end if

    allocate(DiffCoef_VFDB(nDiff,1:nI+1,1:nJ+1,1:nK+1,nDim,MaxBlock))
    DiffCoef_VFDB = 0.0 ! make sure all elements are initialized

  end subroutine init_rad_diffusion

  !============================================================================

  subroutine get_rad_energy_flux( &
       iDir, i, j, k, iBlock, State_V, EradFlux_D)

    !\
    ! Calculate the diffusion part of the radiation energy flux.
    !/
    use ModAdvance,      ONLY: State_VGB, Erad_
    use ModFaceGradient, ONLY: get_face_gradient
    use ModPhysics,      ONLY: Si2No_V, UnitX_, Clight
    use ModTemperature,  ONLY: UseRadFluxLimiter, TypeRadFluxLimiter
    use ModUser,         ONLY: user_material_properties
    use ModVarIndexes,   ONLY: nVar

    integer, intent(in) :: iDir, i, j, k, iBlock
    real,    intent(in) :: State_V(nVar)
    real,    intent(out):: EradFlux_D(3)

    real :: DiffusionOpacitySi, DiffRad
    real :: DiffusionOpacity
    real :: FaceGrad_D(3), Grad2ByErad2
    !--------------------------------------------------------------------------

    if(IsNewBlockRadDiffusion) Erad_G = State_VGB(Erad_,:,:,:,iBlock)

    call get_face_gradient(iDir, i, j, k, iBlock, &
         IsNewBlockRadDiffusion, Erad_G, FaceGrad_D)

    if(IsNewTimestepRadDiffusion)then

       call user_material_properties(State_V, i, j, k, iBlock, iDir, &
            DiffusionOpacitySiOut = DiffusionOpacitySi)

       DiffusionOpacity = DiffusionOpacitySi/Si2No_V(UnitX_)

       if(UseRadFluxLimiter)then
          Grad2ByErad2 = sum(FaceGrad_D**2)/State_V(Erad_)**2

          select case(TypeRadFluxLimiter)
          case("sum")
             DiffRad = Clight/(3*DiffusionOpacity + sqrt(Grad2ByErad2))
          case("max")
             DiffRad = Clight/max(3*DiffusionOpacity,sqrt(Grad2ByErad2))
          case("larsen")
             DiffRad = Clight/sqrt(9*DiffusionOpacity**2 + Grad2ByErad2)
          end select
       else
          DiffRad = Clight/(3*DiffusionOpacity)
       end if

       DiffCoef_VFDB(1,i,j,k,iDir,iBlock) = DiffRad
    else
       DiffRad = DiffCoef_VFDB(1,i,j,k,iDir,iBlock)
    end if

    EradFlux_D = -DiffRad*FaceGrad_D

  end subroutine get_rad_energy_flux

  !============================================================================

  subroutine calc_source_rad_diffusion(iBlock)

    use ModAdvance,    ONLY: State_VGB, Source_VC, &
         uDotArea_XI, uDotArea_YI, uDotArea_ZI, Erad_
    use ModConst,      ONLY: cLightSpeed
    use ModGeometry,   ONLY: vInv_CB, y_BLK, TypeGeometry
    use ModImplicit,   ONLY: UseFullImplicit
    use ModPhysics,    ONLY: cRadiationNo, Si2No_V, UnitTemperature_, UnitT_
    use ModMain,       ONLY: nI, nJ, nK, UseRadDiffusion
    use ModUser,       ONLY: user_material_properties
    use ModVarIndexes, ONLY: Energy_, RhoUy_

    integer, intent(in) :: iBlock

    integer :: i, j, k
    real :: TeSi, Te, DivU
    real :: RadCompression, AbsorptionEmission, PlanckOpacitySi
    character(len=*), parameter:: NameSub = "calc_source_rad_diffusion"
    !------------------------------------------------------------------------

    do k=1,nK; do j=1,nJ; do i=1,nI

       DivU = vInv_CB(i,j,k,iBlock)* &
            ( uDotArea_XI(i+1,j,k,1) - uDotArea_XI(i,j,k,1) &
            + uDotArea_YI(i,j+1,k,1) - uDotArea_YI(i,j,k,1) &
            + uDotArea_ZI(i,j,k+1,1) - uDotArea_ZI(i,j,k,1) )

       ! Adiabatic compression of radiation energy by fluid velocity (fluid 1)
       ! (GammaRel-1)*Erad*Div(U)
       RadCompression = (GammaRel-1.0)*State_VGB(Erad_,i,j,k,iBlock)*DivU

       ! dErad/dt = - adiabatic compression
       Source_VC(Erad_,i,j,k) = Source_VC(Erad_,i,j,k) &
            - RadCompression

       ! dE/dt    = + adiabatic compression
       Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) + RadCompression

       if(.not.UseFullImplicit) CYCLE

       if(IsNewTimestepRadDiffusion)then
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, AbsorptionOpacitySiOut = PlanckOpacitySi)

          RelaxCoef_VCB(1,i,j,k,iBlock) = &
               PlanckOpacitySi*cLightSpeed/Si2No_V(UnitT_)
       end if

       call user_material_properties(State_VGB(:,i,j,k,iBlock), &
            i, j, k, iBlock, TeSiOut = TeSi)

       Te = TeSi*Si2No_V(UnitTemperature_)

       ! Source term due to absorption and emission
       ! Sigma_a*(cRadiation*Te**4-Erad)
       AbsorptionEmission =  RelaxCoef_VCB(1,i,j,k,iBlock) &
            *(cRadiationNo*Te**4 - State_VGB(Erad_,i,j,k,iBlock))

       ! dErad/dt = + AbsorptionEmission
       Source_VC(Erad_,i,j,k) = Source_VC(Erad_,i,j,k) &
            + AbsorptionEmission

       ! dE/dt    = - AbsorptionEmission
       Source_VC(Energy_,i,j,k) = Source_VC(Energy_,i,j,k) &
            - AbsorptionEmission

    end do; end do; end do

    if(TypeGeometry=='rz' .and. UseRadDiffusion)then
       ! Add "geometrical source term" p/r to the radial momentum equation
       ! The "radial" direction is along the Y axis
       ! NOTE: here we have to use signed radial distance!
       do k=1,nK; do j=1, nJ; do i=1, nI
          Source_VC(RhoUy_,i,j,k) = Source_VC(RhoUy_,i,j,k) &
               + (1./3.)*State_VGB(Erad_,i,j,k,iBlock) &
               / y_BLK(i,j,k,iBlock)
       end do; end do; end do
    end if

  end subroutine calc_source_rad_diffusion

  !============================================================================
  ! Semi-implicit interface
  !============================================================================

  subroutine get_impl_rad_diff_state(StateImpl_VGB,DconsDsemi_VCB)

    use ModAdvance,  ONLY: Erad_, State_VGB
    use ModImplicit, ONLY: nw, nImplBlk, impl2iBlk, TypeSemiImplicit, &
         iEradImpl, iTeImpl, ImplCoeff
    use ModMain,     ONLY: nDim, x_, y_, nI, nJ, nK, MaxImplBlk, Dt
    use ModNumConst, ONLY: i_DD
    use ModPhysics,  ONLY: inv_gm1, Clight, cRadiationNo, &
         Si2No_V, UnitTemperature_, UnitEnergyDens_, UnitX_, UnitU_
    use ModUser,     ONLY: user_material_properties
    use ModTemperature, ONLY: UseRadFluxLimiter, TypeRadFluxLimiter
    use ModGeometry, ONLY: dx_BLK, dy_BLK, dz_BLK, vInv_CB, &
         UseCovariant, TypeGeometry, FaceAreaI_DFB, FaceAreaJ_DFB
    use ModParallel, ONLY: NOBLK, NeiLev
    use ModMessagePass, ONLY: message_pass_dir

    real, intent(out) :: StateImpl_VGB(nw,0:nI+1,0:nJ+1,0:nK+1,MaxImplBlk)
    real, intent(inout) :: DconsDsemi_VCB(nw,nI,nJ,nK,MaxImplBlk)

    integer :: iImplBlock, iBlock, i, j, k
    real :: PlanckOpacitySi, PlanckOpacity, CvSi, Cv, TeSi, Te
    real :: DiffusionOpacitySi, DiffusionOpacity
    real :: HeatCondSi, HeatCond
    real :: Grad2ByErad2, DiffRad, InvDx2, InvDy2, InvDz2
    real :: InvDx, InvDy

    integer :: iDim, Di, Dj, Dk, iDiff, nDimInUse
    real :: Coeff, Dxyz_D(3)

    character(len=*), parameter:: NameSub='get_impl_rad_diff_state'
    !--------------------------------------------------------------------------

    do iImplBlock = 1, nImplBLK

       iBlock = impl2iBLK(iImplBlock)
       IsNewBlockRadDiffusion = .true.

       if(TypeSemiImplicit=='radiation' .or. TypeSemiImplicit=='radcond')then
          do k = 0, nK+1; do j = 0, nJ+1; do i = 0, nI+1
             StateImpl_VGB(iEradImpl,i,j,k,iImplBlock) = &
                  State_VGB(Erad_,i,j,k,iBlock)
          end do; end do; end do
       end if
       if(TypeSemiImplicit=='radcond')then
          do k = 0, nK+1; do j = 0, nJ+1; do i = 0, nI+1
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, TeSiOut = TeSi)
             Te = TeSi*Si2No_V(UnitTemperature_)
             StateImpl_VGB(iTeImpl,i,j,k,iImplBlock) = cRadiationNo*Te**4
          end do; end do; end do
       elseif(TypeSemiImplicit=='cond')then
          do k = 0, nK+1; do j = 0, nJ+1; do i = 0, nI+1
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, TeSiOut = TeSi)
             StateImpl_VGB(iTeImpl,i,j,k,iImplBlock) = &
                  TeSi*Si2No_V(UnitTemperature_)
          end do; end do; end do
       end if

       InvDx2 = 0.5/dx_BLK(iBlock)
       InvDy2 = 0.5/dy_BLK(iBlock)
       InvDz2 = 0.5/dz_BLK(iBlock)

       ! calculate coefficients for linearized energy exchange and diffusion
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               i, j, k, iBlock, &
               AbsorptionOpacitySiOut = PlanckOpacitySi, &
               DiffusionOpacitySiOut = DiffusionOpacitySi, &
               CvSiOut = CvSi, TeSiOut = TeSi, &
               HeatCondSiOut = HeatCondSi)

          PlanckOpacity = PlanckOpacitySi/Si2No_V(UnitX_)
          Cv = CvSi*Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_)
          Te = TeSi*Si2No_V(UnitTemperature_)

          select case(TypeSemiImplicit)
          case('radiation')
             ! This coefficient is cR'' = cR/(1+dt*cR*dPlanck/dEint)
             PointSemiCoef_VCB(Relax_,i,j,k,iBlock) = Clight*PlanckOpacity  &
                  /(1 + ImplCoeff*Dt*Clight*PlanckOpacity &
                  *4.0*cRadiationNo*Te**3 / Cv)

             ! This is just the Planck function at time level * saved
             PointSemiCoef_VCB(Planck_,i,j,k,iBlock) = cRadiationNo*Te**4
          case('radcond')
             RelaxCoef_VCB(1,i,j,k,iBlock) = Clight*PlanckOpacity

             DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) = &
                  Cv/(4.0*cRadiationNo*Te**3)
          case('cond')
             DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) = Cv
          end select

          call get_diffusion_coef

       end do; end do; end do

       if(NeiLev(1,iBlock) == NOBLK)then
          i = 0
          do k = 1, nK; do j = 1, nJ
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, &
                  DiffusionOpacitySiOut = DiffusionOpacitySi, &
                  HeatCondSiOut = HeatCondSi, &
                  TeSiOut = TeSi)
             call get_diffusion_coef
          end do; end do
       end if
       if(NeiLev(2,iBlock) == NOBLK)then
          i = nI + 1
          do k = 1, nK; do j = 1, nJ
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, &
                  DiffusionOpacitySiOut = DiffusionOpacitySi, &
                  HeatCondSiOut = HeatCondSi, &
                  TeSiOut = TeSi)
             call get_diffusion_coef
          end do; end do
       end if
       if(NeiLev(3,iBlock) == NOBLK)then
          j = 0
          do k = 1, nK; do i = 1, nI
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, &
                  DiffusionOpacitySiOut = DiffusionOpacitySi, &
                  HeatCondSiOut = HeatCondSi, &
                  TeSiOut = TeSi)
             call get_diffusion_coef
          end do; end do
       end if
       if(NeiLev(4,iBlock) == NOBLK)then
          j = nJ + 1
          do k = 1, nK; do i = 1, nI
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, &
                  DiffusionOpacitySiOut = DiffusionOpacitySi, &
                  HeatCondSiOut = HeatCondSi, &
                  TeSiOut = TeSi)
             call get_diffusion_coef
          end do; end do
       end if
       if(NeiLev(5,iBlock) == NOBLK)then
          k = 0
          do j = 1, nJ; do i = 1, nI
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, &
                  DiffusionOpacitySiOut = DiffusionOpacitySi, &
                  HeatCondSiOut = HeatCondSi, &
                  TeSiOut = TeSi)
             call get_diffusion_coef
          end do; end do
       end if
       if(NeiLev(6,iBlock) == NOBLK)then
          k = nK + 1
          do j = 1, nJ; do i = 1, nI
             call user_material_properties(State_VGB(:,i,j,k,iBlock), &
                  i, j, k, iBlock, &
                  DiffusionOpacitySiOut = DiffusionOpacitySi, &
                  HeatCondSiOut = HeatCondSi, &
                  TeSiOut = TeSi)
             call get_diffusion_coef
          end do; end do
       end if

    end do

    nDimInUse = 3; if(TypeGeometry == 'rz') nDimInUse = 2

    ! Message pass to fill in ghost cells 
    call message_pass_dir(iDirMin=1,iDirMax=3,Width=1, &
         SendCorners=.false.,ProlongOrder=1,nVar=nDiff, &
         Sol_VGB=DiffSemiCoef_VGB,restrictface=.true.)

    do iImplBlock = 1, nImplBLK
       iBlock = impl2iBLK(iImplBlock)
       ! Calculate face averaged values. Include geometric factors.

       call face_equal(1,2,nI,1,nJ,1,nK)
       if(NeiLev(1,iBlock)==0.or.NeiLev(1,iBlock)==NOBLK)then
          call face_equal(1,1,1,1,nJ,1,nK)
       else if(NeiLev(1,iBlock)==-1)then
          call face_left_coarse2fine(1,1,1,1,nJ,1,nK)
       else if(NeiLev(1,iBlock)==1)then
          call face_left_fine2coarse(1,1,1,1,nJ,1,nK)
       end if
       if(NeiLev(2,iBlock)==0.or.NeiLev(2,iBlock)==NOBLK)then
          call face_equal(1,nI+1,nI+1,1,nJ,1,nK)
       else if(NeiLev(2,iBlock)==-1)then
          call face_right_coarse2fine(1,nI+1,nI+1,1,nJ,1,nK)
       else if(NeiLev(2,iBlock)==1)then
          call face_right_fine2coarse(1,nI+1,nI+1,1,nJ,1,nK)
       end if

       call face_equal(2,1,nI,2,nJ,1,nK)
       if(NeiLev(3,iBlock)==0.or.NeiLev(3,iBlock)==NOBLK)then
          call face_equal(2,1,nI,1,1,1,nK)
       else if(NeiLev(3,iBlock)==-1)then
          call face_left_coarse2fine(2,1,nI,1,1,1,nK)
       else if(NeiLev(3,iBlock)==1)then
          call face_left_fine2coarse(2,1,nI,1,1,1,nK)
       end if
       if(NeiLev(4,iBlock)==0.or.NeiLev(4,iBlock)==NOBLK)then
          call face_equal(2,1,nI,nJ+1,nJ+1,1,nK)
       else if(NeiLev(4,iBlock)==-1)then
          call face_right_coarse2fine(2,1,nI,nJ+1,nJ+1,1,nK)
       else if(NeiLev(4,iBlock)==1)then
          call face_right_fine2coarse(2,1,nI,nJ+1,nJ+1,1,nK)
       end if

       if(nDimInUse==3)then
          call face_equal(3,1,nI,1,nJ,2,nK)
          if(NeiLev(5,iBlock)==0.or.NeiLev(5,iBlock)==NOBLK)then
             call face_equal(3,1,nI,1,nJ,1,1)
          else if(NeiLev(5,iBlock)==-1)then
             call face_left_coarse2fine(3,1,nI,1,nJ,1,1)
          else if(NeiLev(5,iBlock)==1)then
             call face_left_fine2coarse(3,1,nI,1,nJ,1,1)
          end if
          if(NeiLev(6,iBlock)==0.or.NeiLev(6,iBlock)==NOBLK)then
             call face_equal(3,1,nI,1,nJ,nK+1,nK+1)
          else if(NeiLev(6,iBlock)==-1)then
             call face_right_coarse2fine(3,1,nI,1,nJ,nK+1,nK+1)
          else if(NeiLev(6,iBlock)==1)then
             call face_right_fine2coarse(3,1,nI,1,nJ,nK+1,nK+1)
          end if
       end if

       if(.not.UseCovariant)then
          Dxyz_D = (/dx_BLK(iBlock), dy_BLK(iBlock), dz_Blk(iBlock)/)
          do iDim = 1, nDim
             ! FaceYZ/dx = Volume/dx^2
             Coeff = 1.0 / (Dxyz_D(iDim)**2 * vInv_CB(1,1,1,iBlock))
             Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
             do k=1,nK+Dk; do j=1,nJ+Dj; do i=1,nI+Di
                do iDiff = 1, nDiff
                   DiffCoef_VFDB(iDiff,i,j,k,iDim,iBlock) = &
                        Coeff*DiffCoef_VFDB(iDiff,i,j,k,iDim,iBlock)
                end do
             enddo; enddo; enddo
          end do

       elseif(TypeGeometry == 'rz')then

          InvDx = 1.0/Dx_Blk(iBlock)
          do k=1,nK; do j=1,nJ; do i=1,nI+1
             do iDiff = 1, nDiff
                DiffCoef_VFDB(iDiff,i,j,k,x_,iBlock) = &
                     InvDx*FaceAreaI_DFB(x_,i,j,k,iBlock) &
                     *DiffCoef_VFDB(iDiff,i,j,k,x_,iBlock)
             end do
          end do; end do; end do

          InvDy = 1.0/Dy_Blk(iBlock)
          do k=1,nK; do j=1,nJ+1; do i=1,nI
             do iDiff = 1, nDiff
                DiffCoef_VFDB(iDiff,i,j,k,y_,iBlock) = &
                     InvDy*FaceAreaJ_DFB(y_,i,j,k,iBlock) &
                     *DiffCoef_VFDB(iDiff,i,j,k,y_,iBlock)
             end do
          end do; end do; end do
       else
          call stop_mpi(NameSub//': unimplemented TypeGeometry=//TypeGeometry')
       end if
    end do

  contains

    subroutine face_equal(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
         DiffCoef_VFDB(:,i,j,k,iDim,iBlock) = 0.5*( &
              DiffSemiCoef_VGB(:,i-Di,j-Dj,k-Dk,iBlock) &
              + DiffSemiCoef_VGB(:,i,j,k,iBlock))
      enddo; enddo; enddo

    end subroutine face_equal

    !==========================================================================

    subroutine face_left_coarse2fine(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
         DiffCoef_VFDB(:,i,j,k,iDim,iBlock) =  &
              (DiffSemiCoef_VGB(:,i,j,k,iBlock) &
              + 2.0*DiffSemiCoef_VGB(:,i-Di,j-Dj,k-Dk,iBlock))*4.0/9.0
      enddo; enddo; enddo

    end subroutine face_left_coarse2fine

    !==========================================================================

    subroutine face_right_coarse2fine(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
         DiffCoef_VFDB(:,i,j,k,iDim,iBlock) =  &
              (DiffSemiCoef_VGB(:,i-Di,j-Dj,k-Dk,iBlock) &
              + 2.0*DiffSemiCoef_VGB(:,i,j,k,iBlock))*4.0/9.0
      enddo; enddo; enddo

    end subroutine face_right_coarse2fine

    !==========================================================================

    subroutine face_left_fine2coarse(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      integer :: iShift, jShift, kShift
      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      iShift = 1-Di; jShift = 1-Dj; kShift = 1-Dk
      do k=kMin,kMax,2-Dk; do j=jMin,jMax,2-Dj; do i=iMin,iMax,2-Di
         do iDiff = 1, nDiff
            DiffCoef_VFDB(iDiff,i:i+iShift,j:j+jShift,k:k+kShift,iDim,iBlock) &
                 = (DiffSemiCoef_VGB(iDiff,i-Di,j-Dj,k-Dk,iBlock) &
                 + 0.5*sum(DiffSemiCoef_VGB( &
                 iDiff,i:i+iShift,j:j+jShift,k:k+kShift,iBlock)))*2.0/9.0
         end do
      enddo; enddo; enddo

    end subroutine face_left_fine2coarse

    !==========================================================================

    subroutine face_right_fine2coarse(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      integer :: iShift, jShift, kShift, i1, j1, k1
      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      iShift = 1-Di; jShift = 1-Dj; kShift = 1-Dk
      do k=kMin,kMax,2-Dk; do j=jMin,jMax,2-Dj; do i=iMin,iMax,2-Di
         i1=i-Di; j1=j-Dj; k1=k-Dk
         do iDiff = 1, nDiff
            DiffCoef_VFDB(iDiff,i:i+iShift,j:j+jShift,k:k+kShift,iDim,iBlock) &
                 = (DiffSemiCoef_VGB(iDiff,i,j,k,iBlock) &
                 + 0.5*sum(DiffSemiCoef_VGB( &
                 iDiff,i1:i1+iShift,j1:j1+jShift,k1:k1+kShift,iBlock)))*2.0/9.0
         end do
      enddo; enddo; enddo

    end subroutine face_right_fine2coarse

    !==========================================================================

    subroutine get_diffusion_coef

      use ModFaceGradient, ONLY: set_block_field

      !------------------------------------------------------------------------

      if(TypeSemiImplicit=='radiation' .or. TypeSemiImplicit=='radcond')then
         DiffusionOpacity = DiffusionOpacitySi/Si2No_V(UnitX_)

         ! Calculate the cell centered diffusion coefficients
         if(UseRadFluxLimiter)then

            if(IsNewBlockRadDiffusion)then
               Erad_G = State_VGB(Erad_,:,:,:,iBlock)
               call set_block_field(iBlock, 1, Erad1_G, Erad_G)

               IsNewBlockRadDiffusion = .false.
            end if
        
            Grad2ByErad2 = &
                 (((Erad_G(i+1,j,k) - Erad_G(i-1,j,k))*InvDx2)**2 &
                 +((Erad_G(i,j+1,k) - Erad_G(i,j-1,k))*InvDy2)**2 &
                 +((Erad_G(i,j,k+1) - Erad_G(i,j,k-1))*InvDz2)**2 &
                 )/ Erad_G(i,j,k)**2

            select case(TypeRadFluxLimiter)
            case("sum")
               DiffRad = Clight/(3*DiffusionOpacity + sqrt(Grad2ByErad2))
            case("max")
               DiffRad = Clight/max(3*DiffusionOpacity,sqrt(Grad2ByErad2))
            case("larsen")
               DiffRad = Clight/sqrt(9*DiffusionOpacity**2 + Grad2ByErad2)
            end select
         else
            DiffRad = Clight/(3*DiffusionOpacity)
         end if

         ! Store it for message passing
         DiffSemiCoef_VGB(iEradImpl,i,j,k,iBlock) = DiffRad
      end if

      if(TypeSemiImplicit=='cond')then
         HeatCond = HeatCondSi &
              *Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_) &
              *Si2No_V(UnitU_)*Si2No_V(UnitX_)

         DiffSemiCoef_VGB(iTeImpl,i,j,k,iBlock) = HeatCond
      elseif(TypeSemiImplicit=='radcond')then
         HeatCond = HeatCondSi &
              *Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_) &
              *Si2No_V(UnitU_)*Si2No_V(UnitX_)
         Te = TeSi*Si2No_V(UnitTemperature_)

         DiffSemiCoef_VGB(iTeImpl,i,j,k,iBlock) = &
              HeatCond/(4.0*cRadiationNo*Te**3)
      end if

    end subroutine get_diffusion_coef

  end subroutine get_impl_rad_diff_state

  !============================================================================

  subroutine set_rad_outflow_bc(iSide, iBlock, iVar, nVar, State_VG)

    use ModImplicit, ONLY: nw
    use ModGeometry, ONLY: dx_BLK, dy_BLK, dz_BLK, vInv_CB
    use ModMain,     ONLY: nI, nJ, nK
    use ModPhysics,  ONLY: Clight, Si2No_V, UnitX_
    use ModUser,     ONLY: user_material_properties

    integer, intent(in) :: iSide, iBlock, iVar, nVar
    real, intent(inout) :: State_VG(nVar,-1:nI+2,-1:nJ+2,-1:nK+2)

    integer :: i, j, k, iDiff
    real :: Coef, OpacitySi
    logical :: IsFullState
    character(len=*), parameter :: NameSub='set_rad_outflow_bc'
    !--------------------------------------------------------------------------
    IsFullState = nVar > nw
    
    iDiff = 1

    select case(iSide)
    case(1)
       do k = 1, nK; do j = 1, nJ
          if(IsFullState)then
             call user_material_properties(State_VG(:,1,j,k), &
                  1, j, k, iBlock, DiffusionOpacitySiOut=OpacitySi)
             Coef = 2/sqrt( &
                  (3 * OpacitySi/Si2No_V(UnitX_) * dx_BLK(iBlock))**2 &
                  + ((State_VG(iVar,2,j,k) - State_VG(iVar,1,j,k)) &
                  /  State_VG(iVar,1,j,k))**2)
          else
             Coef = 2/Clight* &
                  DiffSemiCoef_VGB(iDiff,1,j,k,iBlock)/dx_BLK(iBlock)
          end if
          State_VG(iVar,0,j,k) = State_VG(iVar,1,j,k)*(Coef - 0.5)/(Coef + 0.5)
          if(IsFullState) State_VG(iVar,-1,j,k) &
               = 2*State_VG(iVar,0,j,k) - State_VG(iVar,1,j,k)
       end do; end do
    case(2)
       do k = 1, nK; do j = 1, nJ
          if(IsFullState)then
             call user_material_properties(State_VG(:,nI,j,k), &
                  nI, j, k, iBlock, DiffusionOpacitySiOut=OpacitySi)
             Coef = 2/sqrt( &
                  (3 * OpacitySi/Si2No_V(UnitX_) * dx_BLK(iBlock))**2 &
                  + ((State_VG(iVar,nI,j,k)-State_VG(iVar,nI-1,j,k)) &
                  /   State_VG(iVar,nI,j,k))**2)
          else
             Coef = 2/Clight* &
                  DiffSemiCoef_VGB(iDiff,nI,j,k,iBlock)/dx_BLK(iBlock)
          end if

          State_VG(iVar,nI+1,j,k) = State_VG(iVar,nI,j,k) &
               *(Coef - 0.5)/(Coef + 0.5)
          if(IsFullState) State_VG(iVar,nI+2,j,k) &
               = 2*State_VG(iVar,nI+1,j,k) - State_VG(iVar,nI,j,k)
       end do; end do
    case(3)
       do k = 1, nK; do i = 1, nI
          if(IsFullState)then
             call user_material_properties(State_VG(:,i,1,k), &
                  i, 1, k, iBlock, DiffusionOpacitySiOut=OpacitySi)
             Coef = 2/sqrt( &
                  (3 * OpacitySi/Si2No_V(UnitX_) * dy_BLK(iBlock))**2 &
                  + ((State_VG(iVar,i,2,k) - State_VG(iVar,i,1,k)) &
                  /  State_VG(iVar,i,1,k))**2)
          else
             Coef = 2/Clight* &
                  DiffSemiCoef_VGB(iDiff,i,1,k,iBlock)/dy_BLK(iBlock)
          end if
          State_VG(iVar,i,0,k) = State_VG(iVar,i,1,k)*(Coef - 0.5)/(Coef + 0.5)
          if(IsFullState) State_VG(iVar,i,-1,k) &
               = 2*State_VG(iVar,i,0,k) - State_VG(iVar,i,1,k)
       end do; end do
    case(4)
       do k = 1, nK; do i = 1, nI
          if(IsFullState)then
             call user_material_properties(State_VG(:,i,nJ,k), &
                  i, nJ, k, iBlock, DiffusionOpacitySiOut=OpacitySi)
             Coef = 2/sqrt( &
                  (3 * OpacitySi/Si2No_V(UnitX_) * dy_BLK(iBlock))**2 &
                  + ((State_VG(iVar,i,nJ,k)-State_VG(iVar,i,nJ-1,k)) &
                  /   State_VG(iVar,i,nJ,k))**2)
          else
             Coef = 2/Clight* &
                  DiffSemiCoef_VGB(iDiff,i,nJ,k,iBlock)/dy_BLK(iBlock)
          end if

          State_VG(iVar,i,nJ+1,k) = State_VG(iVar,i,nJ,k) &
               *(Coef - 0.5)/(Coef + 0.5)
          if(IsFullState) State_VG(iVar,i,nJ+2,k) &
               = 2*State_VG(iVar,i,nJ+1,k) - State_VG(iVar,i,nJ,k)
       end do; end do
    case(5)
       do j = 1, nJ; do i = 1, nI
          if(IsFullState)then
             call user_material_properties(State_VG(:,i,j,1), &
                  i, j, 1, iBlock, DiffusionOpacitySiOut=OpacitySi)
             Coef = 2/sqrt( &
                  (3 * OpacitySi/Si2No_V(UnitX_) * dz_BLK(iBlock))**2 &
                  + ((State_VG(iVar,i,j,2) - State_VG(iVar,i,j,1)) &
                  /  State_VG(iVar,i,j,1))**2)
          else
             Coef = 2/Clight* &
                  DiffSemiCoef_VGB(iDiff,i,j,1,iBlock)/dz_BLK(iBlock)
          end if
          State_VG(iVar,i,j,0) = State_VG(iVar,i,j,1)*(Coef - 0.5)/(Coef + 0.5)
          if(IsFullState) State_VG(iVar,i,j,-1) &
               = 2*State_VG(iVar,i,j,0) - State_VG(iVar,i,j,1)
       end do; end do
    case(6)
       do k = j, nJ; do i = 1, nI
          if(IsFullState)then
             call user_material_properties(State_VG(:,i,j,nK), &
                  i, j, nK, iBlock, DiffusionOpacitySiOut=OpacitySi)
             Coef = 2/sqrt( &
                  (3 * OpacitySi/Si2No_V(UnitX_) * dz_BLK(iBlock))**2 &
                  + ((State_VG(iVar,i,j,nK)-State_VG(iVar,i,j,nK-1)) &
                  /   State_VG(iVar,i,j,nK))**2)
          else
             Coef = 2/Clight* &
                  DiffSemiCoef_VGB(iDiff,i,j,nK,iBlock)/dz_BLK(iBlock)
          end if

          State_VG(iVar,i,j,nK+1) = State_VG(iVar,i,j,nK) &
               *(Coef - 0.5)/(Coef + 0.5)
          if(IsFullState) State_VG(iVar,i,j,nK+2) &
               = 2*State_VG(iVar,i,j,nK+1) - State_VG(iVar,i,j,nK)
       end do; end do
    end select

  end subroutine set_rad_outflow_bc

  !============================================================================

  subroutine get_rad_diffusion_rhs(iBlock, StateImpl_VG, Rhs_VC, IsLinear)

    use ModGeometry, ONLY: TypeGeometry, vInv_CB
    use ModImplicit, ONLY: nw, iTeImpl
    use ModMain,     ONLY: nI, nJ, nK
    use ModParallel, ONLY: NeiLev

    integer, intent(in) :: iBlock
    real, intent(inout) :: StateImpl_VG(nw,-1:nI+2,-1:nJ+2,-1:nK+2)
    real, intent(out)   :: Rhs_VC(nw,nI,nJ,nK)
    logical, intent(in) :: IsLinear

    real :: Te, EnergyExchange
    integer :: i, j, k, iDiff, iRelax, iVar
    character(len=*), parameter :: NameSub='get_rad_diffusion_rhs'
    !--------------------------------------------------------------------------

    if(NeiLev(1,iBlock)==1) call correct_left_ghostcell(1,0,0,1,nJ,1,nK)
    if(NeiLev(2,iBlock)==1) call correct_right_ghostcell(1,nI+1,nI+1,1,nJ,1,nK)
    if(NeiLev(3,iBlock)==1) call correct_left_ghostcell(2,1,nI,0,0,1,nK)
    if(NeiLev(4,iBlock)==1) call correct_right_ghostcell(2,1,nI,nJ+1,nJ+1,1,nK)
    if(TypeGeometry /= 'rz')then
       if(NeiLev(5,iBlock)==1) call correct_left_ghostcell(3,1,nI,1,nJ,0,0)
       if(NeiLev(6,iBlock)==1) &
            call correct_right_ghostcell(3,1,nI,1,nJ,nK+1,nK+1)
    end if

    !!! Rhs_VC = 0.0

    if(TypeGeometry == 'rz')then
       ! No flux from Z direction
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          do iDiff = 1, nDiff
             iVar = iDiff_I(iDiff)
             Rhs_VC(iVar,i,j,k) = &
                  vInv_CB(i,j,k,iBlock) * ( &
                  + DiffCoef_VFDB(iDiff,i+1,j,k,1,iBlock)* &
                  (   StateImpl_VG(iVar,i+1,j,k)   &
                  -   StateImpl_VG(iVar,i  ,j,k))  &
                  - DiffCoef_VFDB(iDiff,i  ,j,k,1,iBlock)* &
                  (   StateImpl_VG(iVar,i  ,j,k)   &
                  -   StateImpl_VG(iVar,i-1,j,k))  &
                  + DiffCoef_VFDB(iDiff,i,j+1,k,2,iBlock)* &
                  (   StateImpl_VG(iVar,i,j+1,k)   &
                  -   StateImpl_VG(iVar,i,j  ,k))  &
                  - DiffCoef_VFDB(iDiff,i,j  ,k,2,iBlock)* &
                  (   StateImpl_VG(iVar,i,j  ,k)   &
                  -   StateImpl_VG(iVar,i,j-1,k)) )
          end do
       end do; end do; end do
    else
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          do iDiff = 1, nDiff
             iVar = iDiff_I(iDiff)
             Rhs_VC(iVar,i,j,k) = &
                  vInv_CB(i,j,k,iBlock) * ( &
                  DiffCoef_VFDB(iDiff,i+1,j,k,1,iBlock)*   &
                  (   StateImpl_VG(iVar,i+1,j,k)   &
                  -   StateImpl_VG(iVar,i  ,j,k))  &
                  - DiffCoef_VFDB(iDiff,i  ,j,k,1,iBlock)* &
                  (   StateImpl_VG(iVar,i  ,j,k)   &
                  -   StateImpl_VG(iVar,i-1,j,k))  &
                  + DiffCoef_VFDB(iDiff,i,j+1,k,2,iBlock)* &
                  (   StateImpl_VG(iVar,i,j+1,k)   &
                  -   StateImpl_VG(iVar,i,j  ,k))  &
                  - DiffCoef_VFDB(iDiff,i,j  ,k,2,iBlock)* &
                  (   StateImpl_VG(iVar,i,j  ,k)   &
                  -   StateImpl_VG(iVar,i,j-1,k))  &
                  + DiffCoef_VFDB(iDiff,i,j,k+1,3,iBlock)* &
                  (   StateImpl_VG(iVar,i,j,k+1)   &
                  -   StateImpl_VG(iVar,i,j,k  ))  &
                  - DiffCoef_VFDB(iDiff,i,j,k  ,3,iBlock)* &
                  (   StateImpl_VG(iVar,i,j,k  )   &
                  -   StateImpl_VG(iVar,i,j,k-1)) )
          end do
       end do; end do; end do

    end if

    ! Source terms due to energy exchange
    if(nRelax>0)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          do iRelax = 1, nRelax
             iVar = iRelax_I(iRelax)

             EnergyExchange = RelaxCoef_VCB(iRelax,i,j,k,iBlock) &
                  *(StateImpl_VG(iTeImpl,i,j,k) - StateImpl_VG(iVar,i,j,k))

             ! dEvar/dt = + EnergyExchange
             Rhs_VC(iVar,i,j,k)    = Rhs_VC(iVar,i,j,k)    + EnergyExchange

             ! dEe/dt   = - EnergyExchange
             Rhs_VC(iTeImpl,i,j,k) = Rhs_VC(iTeImpl,i,j,k) - EnergyExchange
          end do
       end do; end do; end do
    end if
       
    ! Point implicit source terms due to energy exchange
    if(nPoint>0)then
       if(IsLinear)then
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             Rhs_VC(iPoint,i,j,k) = Rhs_VC(iPoint,i,j,k) &
                  - PointSemiCoef_VCB(Relax_,i,j,k,iBlock) &
                  *StateImpl_VG(iPoint,i,j,k)
          end do; end do; end do
       else
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             EnergyExchange = PointSemiCoef_VCB(Relax_,i,j,k,iBlock) &
                  * (PointSemiCoef_VCB(Planck_,i,j,k,iBlock) &
                  -  StateImpl_VG(iPoint,i,j,k))

             Rhs_VC(iPoint,i,j,k) = Rhs_VC(iPoint,i,j,k) + EnergyExchange
          end do; end do; end do
       end if
    end if

  contains

    subroutine correct_left_ghostcell(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      use ModNumConst, ONLY: i_DD

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      integer :: i, j, k, iShift, jShift, kShift, Di, Dj, Dk, i1, j1, k1
      integer :: iDiff, iVar
      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      iShift = 1-Di; jShift = 1-Dj; kShift = 1-Dk
      do k=kMin,kMax,2-Dk; do j=jMin,jMax,2-Dj; do i=iMin,iMax,2-Di
         i1=i+Di; j1=j+Dj; k1=k+Dk
         do iDiff = 1, nDiff
            iVar = iDiff_I(iDiff)
            StateImpl_VG(iVar,i:i+iShift,j:j+jShift,k:k+kShift) = &
                 StateImpl_VG(iVar,i:i+iShift,j:j+jShift,k:k+kShift) &
                 + StateImpl_VG(iVar,i1:i1+iShift,j1:j1+jShift,k1:k1+kShift) &
                 -0.25*sum(StateImpl_VG( &
                 iVar,i1:i1+iShift,j1:j1+jShift,k1:k1+kShift))
         end do
      enddo; enddo; enddo

    end subroutine correct_left_ghostcell

    !==========================================================================

    subroutine correct_right_ghostcell(iDim,iMin,iMax,jMin,jMax,kMin,kMax)

      use ModNumConst, ONLY: i_DD

      integer, intent(in) :: iDim, iMin, iMax, jMin, jMax, kMin, kMax

      integer :: i, j, k, iShift, jShift, kShift, Di, Dj, Dk, i1, j1, k1
      integer :: iDiff, iVar
      !------------------------------------------------------------------------

      Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
      iShift = 1-Di; jShift = 1-Dj; kShift = 1-Dk
      do k=kMin,kMax,2-Dk; do j=jMin,jMax,2-Dj; do i=iMin,iMax,2-Di
         i1=i-Di; j1=j-Dj; k1=k-Dk
         do iDiff = 1, nDiff
            iVar = iDiff_I(iDiff)
            StateImpl_VG(iVar,i:i+iShift,j:j+jShift,k:k+kShift) = &
                 StateImpl_VG(iVar,i:i+iShift,j:j+jShift,k:k+kShift) &
                 + StateImpl_VG(iVar,i1:i1+iShift,j1:j1+jShift,k1:k1+kShift) &
                 -0.25*sum(StateImpl_VG( &
                 iVar,i1:i1+iShift,j1:j1+jShift,k1:k1+kShift))
         end do
      enddo; enddo; enddo

    end subroutine correct_right_ghostcell

  end subroutine get_rad_diffusion_rhs

  !============================================================================

  subroutine add_jacobian_rad_diff(iBlock, nVar, Jacobian_VVCI)

    use ModGeometry, ONLY: vInv_CB, dx_BLK, dy_BLK, dz_BLK, &
         fAx_BLK, fAy_BLK, fAz_BLK
    use ModImplicit, ONLY: TypeSemiImplicit, iTeImpl, UseFullImplicit, &
         UseSemiImplicit
    use ModMain,     ONLY: nI, nJ, nK, nDim
    use ModNumConst, ONLY: i_DD

    integer, parameter:: nStencil = 2*nDim + 1

    integer, intent(in) :: iBlock, nVar
    real, intent(out) :: Jacobian_VVCI(nVar,nVar,nI,nJ,nK,nStencil)

    integer :: iVar, i, j, k, iDim, Di, Dj, Dk, iDiff, iRelax
    real :: DiffLeft, DiffRight, RelaxCoef
    real :: Dxyz_D(nDim), Area_D(nDim), Coeff
    !--------------------------------------------------------------------------

    if(nPoint>0.and.UseSemiImplicit)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          ! dSvar/dVar (diagonal)
          Jacobian_VVCI(iPoint,iPoint,i,j,k,1) = &
               -PointSemiCoef_VCB(Relax_,i,j,k,iBlock)
       end do; end do; end do
    end if

    if(nRelax>0.and.UseSemiImplicit)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          do iRelax = 1, nRelax
             iVar = iRelax_I(iRelax)

             RelaxCoef = RelaxCoef_VCB(iRelax,i,j,k,iBlock)

             ! dSvar/dVar (diagonal)
             Jacobian_VVCI(iVar,iVar,i,j,k,1) = -RelaxCoef

             ! dSe/dVar (off diagonal)
             Jacobian_VVCI(iTeImpl,iVar,i,j,k,1) = +RelaxCoef

             ! dSe/daTe^4 (diagonal)
             Jacobian_VVCI(iTeImpl,iTeImpl,i,j,k,1) = -RelaxCoef

             ! dSvar/daTe^4 (off diagonal)
             Jacobian_VVCI(iVar,iTeImpl,i,j,k,1) = +RelaxCoef
          end do
       end do; end do; end do
    end if

    ! For the fully implicit scheme:
    ! add partial derivatives of the gray diffusion term to the Jacobian that
    ! are not calculated by the general algorithm, these are for the diffusion
    ! operators the same as the semi-implicit jacobian.

    Dxyz_D = (/dx_BLK(iBlock), dy_BLK(iBlock), dz_Blk(iBlock)/)
    Area_D = (/fAx_BLK(iBlock), fAy_BLK(iBlock), fAz_BLK(iBlock)/)
    do iDim = 1, nDim
       if(UseFullImplicit) Coeff = -Area_D(iDim)/Dxyz_D(iDim)
       if(UseSemiImplicit) Coeff = 1.0
       Di = i_DD(iDim,1); Dj = i_DD(iDim,2); Dk = i_DD(iDim,3)
       do k=1,nK; do j=1,nJ; do i=1,nI
          do iDiff = 1, nDiff
             iVar = iDiff_I(iDiff)
             DiffLeft = Coeff*vInv_CB(i,j,k,iBlock) &
                  *DiffCoef_VFDB(iDiff,i,j,k,iDim,iBlock)
             DiffRight = Coeff*vInv_CB(i,j,k,iBlock) &
                  *DiffCoef_VFDB(iDiff,i+Di,j+Dj,k+Dk,iDim,iBlock)
             Jacobian_VVCI(iVar,iVar,i,j,k,1) = &
                  Jacobian_VVCI(iVar,iVar,i,j,k,1) - (DiffLeft + DiffRight)

             if(iDim==1.and.i==1 .or. iDim==2.and.j==1 .or. iDim==3.and.k==1)&
                  DiffLeft = 0.0
             if(iDim==1.and.i==nI .or. iDim==2.and.j==nJ &
                  .or. iDim==3.and.k==nK) DiffRight = 0.0

             Jacobian_VVCI(iVar,iVar,i,j,k,2*iDim) = &
                  Jacobian_VVCI(iVar,iVar,i,j,k,2*iDim) + DiffLeft
             Jacobian_VVCI(iVar,iVar,i,j,k,2*iDim+1) = &
                  Jacobian_VVCI(iVar,iVar,i,j,k,2*iDim+1) + DiffRight
          end do
       end do; end do; end do
    end do

  end subroutine add_jacobian_rad_diff

  !============================================================================

  subroutine update_impl_rad_diff(iBlock, iImplBlock, StateImpl_VG)

    use ModAdvance,  ONLY: State_VGB, Rho_, p_, Erad_, ExtraEint_
    use ModEnergy,   ONLY: calc_energy_cell
    use ModImplicit, ONLY: nw, TypeSemiImplicit, iEradImpl, iTeImpl, &
         DconsDsemi_VCB, ImplOld_VCB, ImplCoeff
    use ModMain,     ONLY: nI, nJ, nK, dt
    use ModPhysics,  ONLY: inv_gm1, No2Si_V, Si2No_V, UnitEnergyDens_, UnitP_,&
         UnitRho_, UnitTemperature_
    use ModUser,     ONLY: user_material_properties

    integer, intent(in) :: iBlock, iImplBlock
    real, intent(in) :: StateImpl_VG(nw,nI,nJ,nK)

    integer :: i, j, k
    real :: Einternal, EinternalSi, PressureSi, AbsorptionEmission

    character(len=*), parameter :: NameSub = 'update_impl_rad_diff'
    !--------------------------------------------------------------------------

    if(TypeSemiImplicit=='radiation' .or. TypeSemiImplicit=='radcond')then
       do k = 1,nK; do j = 1,nJ; do i = 1,nI
          State_VGB(Erad_,i,j,k,iBlock) = &
               max(EradMin, StateImpl_VG(iEradImpl,i,j,k))

          if(State_VGB(Erad_,i,j,k,iBlock) < 0.0)then
             write(*,*)NameSub,': ERROR EradMin, EradOrig=', &
                  EradMin, StateImpl_VG(iEradImpl,i,j,k)

             write(*,*)NameSub,': ERROR negative Erad =', &
                  State_VGB(Erad_,i,j,k,iBlock)
             write(*,*)NameSub,': ERROR at i,j,k,iBlock=', i, j, k, iBlock
             call stop_mpi(NameSub//' negative Erad')
          end if
       end do; end do; end do
    end if
    
    do k = 1,nK; do j = 1,nJ; do i = 1,nI
       if(TypeSemiImplicit=='radiation')then
          AbsorptionEmission = ImplCoeff &
               *PointSemiCoef_VCB(Relax_,i,j,k,iBlock) &
               * (PointSemiCoef_VCB(Planck_,i,j,k,iBlock) &
               -  State_VGB(Erad_,i,j,k,iBlock)) &
               + (1.0-ImplCoeff)*PointSemiCoef_VCB(Relax_,i,j,k,iBlock) &
               *(PointSemiCoef_VCB(Planck_,i,j,k,iBlock) &
               - ImplOld_VCB(iEradImpl,i,j,k,iBlock))
               
          Einternal = inv_gm1*State_VGB(p_,i,j,k,iBlock) &
               + State_VGB(ExtraEint_,i,j,k,iBlock) &
               - dt*AbsorptionEmission
       else
          Einternal = inv_gm1*State_VGB(p_,i,j,k,iBlock) &
               + State_VGB(ExtraEint_,i,j,k,iBlock) &
               + DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) &
               *( StateImpl_VG(iTeImpl,i,j,k) &
               -  ImplOld_VCB(iTeImpl,i,j,k,iBlock) )
       end if
       EinternalSi = Einternal*No2Si_V(UnitEnergyDens_)

       if(Einternal < 0.0)then
          write(*,*)NameSub,': ERROR Rho, p, TOrigSi=', &
               State_VGB(Rho_,i,j,k,iBlock)*No2Si_V(UnitRho_), &
               State_VGB(p_,i,j,k,iBlock)*No2Si_V(UnitP_), &
               State_VGB(p_,i,j,k,iBlock)/State_VGB(Rho_,i,j,k,iBlock) &
               *No2Si_V(UnitTemperature_)

          write(*,*)NameSub,': ERROR negative Eint=', Einternal
          write(*,*)NameSub,': ERROR at i,j,k,iBlock=', i, j, k, iBlock
          call stop_mpi(NameSub//' negative Eint')
       end if

       call user_material_properties(State_VGB(:,i,j,k,iBlock), &
            i, j, k, iBlock, &
            EinternalSiIn = EinternalSi, PressureSiOut = PressureSi)

       State_VGB(p_,i,j,k,iBlock) = PressureSi*Si2No_V(UnitP_)

       State_VGB(ExtraEint_,i,j,k,iBlock) = &
            Einternal - inv_gm1*State_VGB(p_,i,j,k,iBlock)

    end do; end do; end do

    call calc_energy_cell(iBlock)

  end subroutine update_impl_rad_diff

end module ModMultiGroupDiffusion
