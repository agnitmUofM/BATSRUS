!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModBuffer

  use BATL_lib, ONLY: &
       test_start, test_stop
  use ModNumConst,  ONLY: cHalfPi, cTwoPi
  use BATL_lib,     ONLY: MaxDim
  implicit none
  save
  ! Named indexes for the spherical buffer
  integer, parameter :: BuffR_  =1, BuffLon_ =  2, BuffLat_ =  3

  ! Number of buffer grid points, along radial, longitudinal and latitudinal
  ! dirctions
  integer            :: nRBuff = 2, nLonBuff = 90, nLatBuff = 45

  ! Buffer grid with dimension(nVar, nRBuff, 0:nLonBuff+1, 0:nLatBuff+1).
  ! There are layers of grid points to implement periodic BCs in longitude
  ! and across-the-pole interpolation in latitude.
  real,  allocatable :: BufferState_VG(:,:,:,:)

  ! Mesh sizes
  real               :: dSphBuff_D(MaxDim)
  ! Minimum and maximum coordinate values. For radius the use of UnitX_
  ! is assumed, while the longitude and latitude are expressed in radians
  real               :: BufferMin_D(MaxDim) = [ 19.0,    0.0, -cHalfPi]
  real               :: BufferMax_D(MaxDim) = [ 21.0, cTwoPi,  cHalfPi]

  ! The magnetic field and velocity vectors on grid are in the coordinate
  ! system as used in the "source" model (in SC, if the grid is applied in
  ! the IH). Therefore, we need both the coordinate system identifier from
  ! the source model...
  character (len=3)  :: TypeCoordSource = '???'
  ! ...and the matrix to convert the coordinate, velocity and the
  ! magnetic field vectors between the buffer grid and the model one:
  real               :: SourceTarget_DD(MaxDim, MaxDim)
  ! To figure out, if the time-dependent conversion matrix needs to be
  ! recalculated for a new time step
  real               :: TimeSimulationLast = -1.0
  ! If the logical below is true the buffer may be restarted, even is the
  ! source model is not used/configured in the restarted run.
  logical            :: DoRestartBuffer = .false.
contains
  !============================================================================
  subroutine init_buffer_grid
    use ModVarIndexes, ONLY: nVar
    use ModMain,       ONLY: rLowerModel
    integer  :: nCell_D(3)
    !--------------------------------------------------------------------------
    if(allocated(BufferState_VG))deallocate(BufferState_VG)
    allocate(BufferState_VG(nVar, nRBuff, 0:nLonBuff+1, 0:nLatBuff+1))
    ! Calculate grid spacing and save
    nCell_D = [nRBuff, nLonBuff, nLatBuff]
    dSphBuff_D = (BufferMax_D - BufferMin_D)/real(nCell_D)
    dSphBuff_D(BuffR_) = (BufferMax_D(BuffR_) - BufferMin_D(BuffR_)) &
         /real(nRBuff - 1)
    ! Assign the lower limit for LOS intergation, for the given model:
    rLowerModel = BufferMax_D(BuffR_)
  end subroutine init_buffer_grid
  !============================================================================
  subroutine read_buffer_grid_param(NameCommand)
    ! Read all parameters from the parameter file and/or restart header file
    use ModReadParam, ONLY: read_var
    ! The longitude and latitude range are read in degrees and then converted
    ! to radians
    use ModNumConst,  ONLY: cDegToRad
    ! At the time the use of buffer grid is expected in IH or OH, but not in
    ! SC
    use ModMain,      ONLY: NameThisComp
    character(LEN=*), intent(in) :: NameCommand
    character(len=*), parameter:: NameSub = 'read_buffer_grid_param'
    !--------------------------------------------------------------------------
    select case(NameCommand)
    case("#HELIOBUFFERGRID")
       if(NameThisComp == 'SC') &
            call stop_mpi(NameSub//' ERROR:'// &
            ' #HELIOBUFFERGRID can be used in IH and OH components only')
       call read_var('nRBuff'    ,  nRBuff)
       call read_var('nLonBuff'  ,  nLonBuff)
       call read_var('nLatBuff'  ,  nLatBuff)
       call read_var('RBuffMin'  ,  BufferMin_D(BuffR_))
       call read_var('RBuffMax'  ,  BufferMax_D(BuffR_))
       BufferMin_D(BuffLon_:BuffLat_) = [0.0   , -cHalfPi]
       BufferMax_D(BuffLon_:BuffLat_) = [cTwoPi,  cHalfPi]
       call init_buffer_grid
    case("#BUFFERGRID")
       call read_var('nRBuff'    ,  nRBuff)
       call read_var('nLonBuff'  ,  nLonBuff)
       call read_var('nLatBuff'  ,  nLatBuff)
       call read_var('RBuffMin'  ,  BufferMin_D(BuffR_))
       call read_var('RBuffMax'  ,  BufferMax_D(BuffR_))
       call read_var('LonBuffMin',  BufferMin_D(BuffLon_))
       call read_var('LonBuffMax',  BufferMax_D(BuffLon_))
       call read_var('LatBuffMin',  BufferMin_D(BuffLat_))
       call read_var('LatBuffMax',  BufferMax_D(BuffLat_))

       ! Convert degrees to radians, latitude to co-latitude
       BufferMin_D(BuffLon_:BuffLat_) = BufferMin_D(BuffLon_:BuffLat_)&
            *cDegToRad
       BufferMax_D(BuffLon_:BuffLat_) = BufferMax_D(BuffLon_:BuffLat_)&
            *cDegToRad
       call init_buffer_grid
    case("#RESTARTBUFFERGRID")
       call read_var('DoRestartBuffer', DoRestartBuffer)
       if(DoRestartBuffer)call read_var('TypeCoordSource', TypeCoordSource)
    end select
  end subroutine read_buffer_grid_param
  !============================================================================
  subroutine get_from_spher_buffer_grid(XyzTarget_D, nVar, State_V)
    use ModMain,       ONLY: TypeCoordSystem, Time_Simulation, &
         DoThinCurrentSheet
    use CON_axes,      ONLY: transform_matrix, transform_velocity
    use ModAdvance,    ONLY: UseB
    use ModWaves,      ONLY: UseAlfvenWaves
    use ModPhysics,    ONLY: No2Si_V, Si2No_V, UnitU_, UnitX_
    use ModVarIndexes, ONLY: Ux_, Uz_, RhoUx_, RhoUz_, SignB_,  Rho_,&
         WaveFirst_, WaveLast_, Bx_, Bz_
    use ModCoordTransform, ONLY: xyz_to_rlonlat
    integer,intent(in) :: nVar
    real,   intent(in) :: XyzTarget_D(MaxDim)
    real,   intent(out):: State_V(nVar)

    real              :: Sph_D(MaxDim)
    real              :: Ewave
    real              :: XyzSource_D(MaxDim)

    !--------------------------------------------------------------------------
    if(TypeCoordSource /= TypeCoordSystem) then
       ! Convert target coordinates to the coordiante system of the model

       if(Time_Simulation > TimeSimulationLast)then
          SourceTarget_DD = transform_matrix(&
               Time_Simulation, TypeCoordSystem, TypeCoordSource)
          TimeSimulationLast = Time_Simulation
       end if
       XyzSource_D = matmul(SourceTarget_DD, XyzTarget_D)
    else
       XyzSource_D = XyzTarget_D
    end if

    call xyz_to_rlonlat(XyzSource_D, Sph_D)

    ! Get the target state from the spherical buffer grid
    call interpolate_from_global_buffer(Sph_D, nVar, State_V)
    ! Transform vector variables from SC to IH
    if(TypeCoordSource /= TypeCoordSystem)then
       State_V(Ux_:Uz_) = transform_velocity(Time_Simulation,&
            State_V(Ux_:Uz_)*No2Si_V(UnitU_), XyzSource_D * No2Si_V(UnitX_), &
            TypeCoordSource, TypeCoordSystem)*Si2No_V(UnitU_)
       if(UseB) State_V(Bx_:Bz_) = matmul( State_V(Bx_:Bz_), SourceTarget_DD)
    end if
    ! Transform to primitive variables
    State_V(Ux_:Uz_) = State_V(RhoUx_:RhoUz_)/State_V(Rho_)
    if(SignB_>1)then
       if(DoThinCurrentSheet)then
          ! In both IH and OH we have no B0, so we ignore that !
          if(sum(State_V(Bx_:Bz_)*XyzTarget_D) < 0.0)then
             State_V(Bx_:Bz_) = -State_V(Bx_:Bz_)
             if(WaveFirst_ > 1 .and. UseAlfvenWaves)then
                Ewave = State_V(WaveFirst_)
                State_V(WaveFirst_) = State_V(WaveLast_)
                State_V(WaveLast_) = Ewave
             end if
             State_V(SignB_)=-1.0
          else
             State_V(SignB_)= 1.0
          end if
       else
          State_V(SignB_) = 0.0
       end if
    end if
  end subroutine get_from_spher_buffer_grid
  !============================================================================
  subroutine interpolate_from_global_buffer(SphSource_D, nVar, Buffer_V)
    ! DESCRIPTION
    ! This subroutine is used to interpolate from  state variables defined on a
    ! spherical buffer grid into the input point SphSource_D.
    ! The buffer grid overlaps some part of the computational grid of a
    ! source component that is coupled to this component.
    ! The buffer grid  has the same coordinate system as the source component
    ! (but may have a different grid resolution).
    ! It is assumed that the buffer grid was filled with the state vector from
    ! the source component at some earlier stage.

    ! INPUT:
    ! SphSource_D is associated with a point in the target component, and it
    ! is assumed that is was already converted to the source coordinate system.

    ! nVar is the number of state variables used in coupling the two components.

    ! Implicit inputs to this subroutine are the buffer grid size, points
    ! and the state vector at each point (USEd from BATSRUS).

    ! OUTPUT:
    ! Buffer_V is the state vector resulting from the interpolation.

    use ModInterpolate, ONLY: trilinear
    ! Input and output variables
    real,intent(in)    :: SphSource_D(3)
    integer,intent(in) :: nVar
    real,intent(out)   :: Buffer_V(nVar)

    real               :: NormSph_D(3)

    ! Convert to normalized coordinates.
    ! Radial is node centered, theta and phi are cell centered.
    character(len=*), parameter:: NameSub = 'interpolate_from_global_buffer'
    !--------------------------------------------------------------------------
    NormSph_D = (SphSource_D - BufferMin_D)/dSphBuff_D + [ 1.0, 0.5, 0.5 ]

    Buffer_V = trilinear(BufferState_VG, nVar, 1, nRBuff,0, nLonBuff+1, &
         0, nLatBuff+1, NormSph_D, DoExtrapolate=.true.)

  end subroutine interpolate_from_global_buffer
  !============================================================================
  subroutine plot_buffer(iFile)
    use ModPlotFile,   ONLY: save_plot_file
    use ModNumConst,   ONLY: cRadToDeg
    use ModAdvance,    ONLY: UseElectronPressure, UseAnisoPressure
    use ModVarIndexes, ONLY: nVar, Rho_, Ux_, Uz_, RhoUx_, RhoUz_, Bx_, Bz_, &
         p_, WaveFirst_, WaveLast_, Pe_, Ppar_, Ehot_, ChargeStateFirst_,    &
         ChargeStateLast_
    use ModIO,            ONLY: NamePrimitiveVarOrig, NamePlotDir
    use ModTimeConvert,   ONLY: time_real_to_int
    use ModCoordTransform, ONLY: rlonlat_to_xyz
    use ModMain,          ONLY: StartTime, Time_Simulation, x_, z_, n_step
    use ModPhysics,       ONLY: No2Si_V, UnitRho_, UnitU_, UnitB_, UnitX_,   &
         UnitP_, UnitEnergyDens_
    use BATL_lib,     ONLY: iProc
    integer, intent(in):: iFile          ! Unused
    integer            :: iTimePlot_I(7) ! To shape the file name
    integer            :: iR, iLon, iLat ! Coordinate indexes
    real               :: R, Lat, Lon    ! Coords
    ! Xyz and state variables to plot
    real               :: State_VII(3 + nVar, nLonBuff, nLatBuff)
    ! Coords: Longitude, Latitude, in degrees
    real               :: Coord_DII(2, nLonBuff, nLatBuff)
    character(LEN=30)::NameFile
    !--------------------------------------------------------------------------
    if(iProc/=0)RETURN ! May be improved
    ! Convert time to integers:
    call time_real_to_int(StartTime + Time_Simulation, iTimePlot_I)
    ! Independing on nRBuff, plot only two 2D files for spherical surfaces
    ! of radius of BufferMin_D(BuffR_) and BufferMax_D(BuffR_)
    do iR = 1, nRBuff, nRBuff - 1
       R = BufferMin_D(BuffR_) + dSphBuff_D(BuffR_)*(iR - 1)
       ! Shape the file name
       write(NameFile,'(a,i2.2,a,i4.4,a,5(i2.2,a))')'R=',nint(R),'Rs_',&
            iTimePlot_I(1),'_',iTimePlot_I(2),'_',iTimePlot_I(3),'_',&
            iTimePlot_I(4),'_',iTimePlot_I(5),'_',iTimePlot_I(6),'.out'
       do iLat = 1, nLatBuff
          Lat = BufferMin_D(BuffLat_) + dSphBuff_D(BuffLat_)*(iLat - 0.50)
          Coord_DII(2,:,iLat) = Lat*cRadToDeg
          do iLon = 1, nLonBuff
             Lon = BufferMin_D(BuffLon_) + dSphBuff_D(BuffLon_)*(iLon  - 0.50)
             Coord_DII( 1,iLon,iLat) = Lon*cRadToDeg
             ! Save Cartesian coordinates
             call rlonlat_to_xyz(R, Lon, Lat, State_VII(x_:z_,iLon,iLat))
             ! Save Buffer state vector
             State_VII(z_+1:z_+nVar, iLon, iLat) = &
                  BufferState_VG(:, iR, iLon, iLat)
             ! Transform to primitive variables:
             State_VII(z_+Ux_:z_+Uz_, iLon, iLat) = &
                  State_VII(z_+RhoUx_:z_+RhoUz_, iLon, iLat)/&
                  State_VII(z_+Rho_, iLon, iLat)
          end do
       end do
       ! Convert from normalized units to SI
       State_VII(  x_:z_,:,:) = State_VII(  x_:z_,:,:)*No2Si_V(UnitX_  )
       State_VII(z_+rho_,:,:) = State_VII(z_+rho_,:,:)*No2Si_V(UnitRho_)
       State_VII(z_+Ux_:z_+Uz_,:,:)   = State_VII(z_+Ux_:z_+Uz_,:,:)*&
            No2Si_V(UnitU_)
       State_VII(z_+Bx_:z_+Bz_,:,:)   = State_VII(z_+Bx_:z_+Bz_,:,:)*&
            No2Si_V(UnitB_)

       if(WaveFirst_ > 1)State_VII(z_+WaveFirst_:z_+WaveLast_,:,:) = &
            State_VII(z_+WaveFirst_:z_+WaveLast_,:,:)* &
            No2Si_V(UnitEnergyDens_)

       if(ChargeStateFirst_ > 1)&
            State_VII(z_+ChargeStateFirst_:z_+ChargeStateLast_,:,:) = &
            State_VII(z_+ChargeStateFirst_:z_+ChargeStateLast_,:,:)* &
            No2Si_V(UnitRho_)

       State_VII(z_+p_,:,:)  = State_VII(z_+p_,:,:)*No2Si_V(UnitP_)
       if(UseElectronPressure)State_VII(z_+Pe_,:,:)  = &
            State_VII(z_+Pe_,:,:)*No2Si_V(UnitP_)

       if(UseAnisoPressure)State_VII(z_+Ppar_,:,:)  = &
            State_VII(z_+Ppar_,:,:)*No2Si_V(UnitP_)

       if(Ehot_>1)State_VII(z_+Ehot_,:,:) = &
            State_VII(z_+Ehot_,:,:)*No2Si_V(UnitEnergyDens_)

       call save_plot_file(trim(NamePlotDir)//NameFile,&
            StringHeaderIn=&
            'SC-IH interface: longitude and latitude are in deg, other in SI',&
            NameVarIn    = &
            'Long Lat x y z '//NamePrimitiveVarOrig//' R',&
            nDimIn=2,      &
            nStepIn=n_step, TimeIn=Time_Simulation,&
            ParamIn_I=[R*No2Si_V(UnitX_)], &
            CoordIn_DII=Coord_DII, &
            VarIn_VII=State_VII)
    end do
  end subroutine plot_buffer
  !============================================================================
  subroutine  save_buffer_restart
    use ModMain,       ONLY: NameThisComp
    use ModIoUnit,     ONLY: UnitTmp_
    use ModUtilities,  ONLY: open_file, close_file
    character(len=*), parameter:: NameSub = 'save_buffer_restart'
    !--------------------------------------------------------------------------
    call open_file(file=NameThisComp//'/restartOUT/buffer.dat', &
         form='UNFORMATTED', NameCaller=NameSub)
    write(UnitTmp_)BufferState_VG(:,:,1:nLonBuff,1:nLatBuff)
    call close_file
  end subroutine save_buffer_restart
  !============================================================================
  subroutine write_buffer_restart_header(iFile)
    use ModUtilities, ONLY: cTab
    integer, intent(in) :: iFile
    !--------------------------------------------------------------------------
    write(iFile,'(a)')'#RESTARTBUFFERGRID'
    write(iFile,'(a)')'T'//cTab//cTab//cTab//'DoRestartBuffer'
    write(iFile,'(a)')TypeCoordSource//cTab//cTab//cTab//'TypeCoordSource'
    write(iFile,*)
    write(iFile,'(a)')'#BUFFERGRID'
    write(iFile,'(i8,a)')nRBuff, cTab//cTab//'nRBuff'
    write(iFile,'(i8,a)')nLonBuff, cTab//cTab//'nLonBuff'
    write(iFile,'(i8,a)')nlatBuff, cTab//cTab//'nLatBuff'
    write(iFile,'(es22.15,a)') &
         BufferMin_D(BuffR_), cTab//cTab//'RBuffMin'
    write(iFile,'(es22.15,a)') &
         BufferMax_D(BuffR_), cTab//cTab//'RBuffMax'
    write(iFile,'(a)')'0.0'//&
         cTab//cTab//cTab//'LonBuffMin'
    write(iFile,'(a)')'360.0'//&
         cTab//cTab//cTab//'LonBuffMax'
    write(iFile,'(a)')'-90.0'//&
         cTab//cTab//cTab//'LatBuffMin'
    write(iFile,'(a)')'90.0'//&
         cTab//cTab//cTab//'LatBuffMax'
    write(iFile,*)
  end subroutine write_buffer_restart_header
  !============================================================================
  subroutine  read_buffer_restart
    use ModMain,       ONLY: NameThisComp
    use ModIoUnit,     ONLY: UnitTmp_
    use ModUtilities,  ONLY: open_file, close_file
    character(len=*), parameter:: NameSub = 'read_buffer_restart'
    !--------------------------------------------------------------------------
    call open_file(file=NameThisComp//'/restartIN/buffer.dat', &
         status='old', form='UNFORMATTED', NameCaller=NameSub)
    read(UnitTmp_)BufferState_VG(:,:,1:nLonBuff,1:nLatBuff)
    call close_file
    call fill_in_buffer_grid_gc
  end subroutine read_buffer_restart
  !============================================================================
  logical function is_buffered_point(i,j,k,iBlock)
    use ModGeometry, ONLY: R_BLK
    integer, intent(in):: i, j, k, iBlock
    !--------------------------------------------------------------------------
    is_buffered_point =   R_BLK(i,j,k,iBlock) <= BufferMax_D(1) &
         .and.            R_BLK(i,j,k,iBlock) >= BufferMin_D(1)
  end function is_buffered_point
  !============================================================================
  subroutine fill_in_from_buffer(iBlock)
    use ModAdvance, ONLY: nVar, State_VGB, Rho_, RhoUx_, RhoUz_, Ux_, Uz_
    use BATL_lib,   ONLY: MinI, MaxI, MinJ, MaxJ, MinK, MaxK, Xyz_DGB, iProc, &
         test_start, test_stop
    integer,intent(in)::iBlock

    integer:: i, j, k
    logical:: DoWrite=.true.
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'fill_in_from_buffer'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    if(DoWrite)then
       DoWrite=.false.
       if(iProc==0)then
          write(*,*)'Fill in the cells near the inner boundary from the buffer'
       end if
    end if

    do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
       if(.not.is_buffered_point(i, j, k, iBlock)) CYCLE

       ! Get interpolated values from buffer grid:
       call get_from_spher_buffer_grid(&
            Xyz_DGB(:,i,j,k,iBlock), nVar, State_VGB(:,i,j,k,iBlock))

       ! Transform primitive variables to conservative ones:
       State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock) = &
            State_VGB(Rho_,i,j,k,iBlock)*State_VGB(Ux_:Uz_,i,j,k,iBlock)

    end do; end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine fill_in_from_buffer
  !============================================================================
  subroutine fix_buffer_grid(iBlock)

    ! Do not update solution in the domain covered by the buffer grid

    use ModAdvance, ONLY: State_VGB, StateOld_VGB, Energy_GBI, EnergyOld_CBI
    use BATL_lib,   ONLY: nI, nJ, nK, &
         test_start, test_stop
    integer, intent(in):: iBlock

    integer:: i, j, k
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'fix_buffer_grid'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       if(.not.is_buffered_point(i, j, k, iBlock))CYCLE
       State_VGB(:,i,j,k,iBlock) = &
            StateOld_VGB(:,i,j,k,iBlock)
       Energy_GBI(i, j, k, iBlock,:) = EnergyOld_CBI(i, j, k, iBlock,:)
    end do; end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine fix_buffer_grid
  !============================================================================
  subroutine match_ibc
    ! restore old values in the domain covered by the buffer grid
    use ModGeometry, ONLY:R_BLK
    use BATL_lib,  ONLY: Xyz_DGB, iProc
    use ModMain,   ONLY: nI, nJ, nK, MaxDim, nBlock, Unused_B
    use ModAdvance, ONLY:nVar,State_VGB,rho_,rhoUx_,rhoUz_,Ux_,Uz_
    integer  :: iBlock
    integer  :: i,j,k
    real     :: x_D(MaxDim), rBuffMax
    !--------------------------------------------------------------------------
    rBuffMax = BufferMax_D(BuffR_)

    ! Fill all spatial domain with values depend on the BC
    do iBlock = 1, nBlock
       if(Unused_B(iBlock))CYCLE

       ! Fill in the physical cells, which are outside the buffer grid
       ! When testing, do not fill cells outside the buffer
       do k = 1, nK; do j = 1 , nJ; do i = 1, nI
          if(R_BLK(i,j,k,iBlock) < rBuffMax)CYCLE

          ! For each grid point, get the values at the base (buffer)
          x_D = Xyz_DGB(:,i,j,k,iBlock)*rBuffMax/R_BLK(i,j,k,iBlock)

          ! The grid point values are extracted from the base values
          call get_from_spher_buffer_grid(&
               x_D, nVar, State_VGB(:,i,j,k,iBlock))

          ! Transform primitive variables to conservative ones:
          State_VGB(rhoUx_:rhoUz_,i,j,k,iBlock)=&
               State_VGB(Ux_:Uz_,i,j,k,iBlock)*&
               State_VGB(rho_,i,j,k,iBlock)

          ! Scale as (r/R)^2:
          State_VGB(:,i,j,k,iBlock)=&
               State_VGB(:,i,j,k,iBlock)*&
               (rBuffMax/R_BLK(i,j,k,iBlock))**2

       end do; end do; end do
    end do
  end subroutine match_ibc
  !============================================================================
  subroutine fill_in_buffer_grid_gc
    ! Fill in the buffer grid ghost cells:
    ! For longitude: using periodic BCs at 0th and 360 degrees longitude
    ! For latitude: interpolation across the pole
    integer   :: iLonNew, iBlock, iPe, iR, iLon, iLat
    !--------------------------------------------------------------------------
    ! Fill buffer grid ghost cells
    do iLon = 1, nLonBuff
       iLonNew = iLon + nLonBuff/2
       if (iLonNew > nLonBuff) iLonNew = iLonNew - nLonBuff
       BufferState_VG(:,:,iLon, 0)         = BufferState_VG(:,:,iLonNew, 1)
       BufferState_VG(:,:,iLon,nLatBuff+1) = &
            BufferState_VG(:,:,iLonNew, nLatBuff)
    end do
    BufferState_VG(:,:,0,:)          = BufferState_VG(:,:,nLonBuff,:)
    BufferState_VG(:,:,nLonBuff+1,:) = BufferState_VG(:,:,1,:)
  end subroutine fill_in_buffer_grid_gc
  !============================================================================

end module ModBuffer
!==============================================================================
