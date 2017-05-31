!  Copyright (C) 2002 Regents of the University of Michigan, 
!  portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module BATL_pass_face

  ! Possible improvements:
  ! (1) Overlapping communication and calculation

  implicit none

  SAVE

  private ! except

  public message_pass_face
  public store_face_flux
  public correct_face_flux
  public apply_flux_correction
  public apply_flux_correction_block
  public test_pass_face

contains

  subroutine message_pass_face(nVar, Flux_VXB, Flux_VYB, Flux_VZB, &
       DoSubtractIn, DoResChangeOnlyIn, MinLevelSendIn, DoTestIn)

    use BATL_size, ONLY: MaxBlock, &
         nBlock, nI, nJ, nK, nIjk_D, &
         MaxDim, nDim, iRatio, jRatio, kRatio

    use BATL_mpi, ONLY: iComm, nProc, iProc

    use BATL_tree, ONLY: &
         iNodeNei_IIIB, DiLevelNei_IIIB, Unused_B, Unused_BP, iNode_B, &
         iTree_IA, Proc_, Block_, Coord1_, Coord2_, Coord3_, Level_, &
         UseTimeLevel, iTimeLevel_A

    use BATL_geometry, ONLY: &
         IsCylindricalAxis, IsSphericalAxis, IsLatitudeAxis, Lat_, Theta_

    use BATL_grid, ONLY: &
         CoordMin_DB, CoordMax_DB

    use ModNumConst, ONLY: i_DD, cHalfPi, cPi
    use ModMpi

    ! Arguments
    integer, intent(in) :: nVar
    real, optional, intent(inout):: &
         Flux_VXB(nVar,nJ,nK,2,MaxBlock), &
         Flux_VYB(nVar,nI,nK,2,MaxBlock), &
         Flux_VZB(nVar,nI,nJ,2,MaxBlock)

    ! Optional arguments
    logical, optional, intent(in) :: DoSubtractIn
    logical, optional, intent(in) :: DoResChangeOnlyIn
    logical, optional, intent(in) :: DoTestIn
    integer, optional, intent(in) :: MinLevelSendIn

    ! Send sum of fine fluxes to coarse neighbors and 
    ! subtract it from the coarse flux if DoSubtractIn is true (default), or
    ! replace original flux with sum of fine fluxes if DoSubtractIn is false.
    ! 
    ! DoResChangeOnlyIn determines if the flux correction is applied at
    !     resolution changes only. True is the default.
    !
    ! MinLevelSendIn determines the lowest level of grid or time level
    ! that should be sending face fluxes.

    ! Local variables

    logical :: DoSubtract, DoReschangeOnly

    integer :: iDim, iDimSide, iRecvSide, iSign
    integer :: iSend, jSend, kSend, iSide, jSide, kSide
    integer :: iDir, jDir, kDir
    integer :: iNodeRecv, iNode
    integer :: iBlockRecv, iProcRecv, iBlock, iProcSend, DiLevel

    ! Fast lookup tables for index ranges per dimension
    integer, parameter:: Min_=1, Max_=2
    integer:: iReceive_DII(MaxDim,0:2,Min_:Max_)

    ! Index range for recv and send segments of the blocks
    integer :: iRMin, iRMax, jRMin, jRMax, kRMin, kRMax

    ! Variables related to recv and send buffers
    integer, parameter:: nFaceCell = max(nI*nJ,nI*nK,nJ*nK)

    integer, allocatable, save:: iBufferR_P(:), iBufferS_P(:)

    integer :: MaxBufferS = -1, MaxBufferR = -1, DnBuffer
    real, pointer, save:: BufferR_IP(:,:), BufferS_IP(:,:)

    integer:: iRequestR, iRequestS, iError
    integer, allocatable, save:: iRequestR_I(:), iRequestS_I(:), &
         iStatus_II(:,:)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'BATL_pass_face::message_pass_face'
    !--------------------------------------------------------------------------
    DoTest = .false.; if(present(DoTestIn)) DoTest = DoTestIn
    if(DoTest)write(*,*)NameSub,' starting with nVar=',nVar

    ! Set values or defaults for optional arguments
    DoSubtract = .true.
    if(present(DoSubtractIn)) DoSubtract = DoSubtractIn

    DoResChangeOnly = .true.
    if(present(DoResChangeOnlyIn)) DoResChangeOnly = DoResChangeOnlyIn

    if(.not. DoReschangeOnly .and. .not. UseTimeLevel) call CON_stop( &
         NameSub//' called with DoResChangeOnly=F while UseTimeLevel=F')

    ! Set index ranges based on arguments
    call set_range

    if(nProc > 1)then
       ! Small arrays are allocated once 
       if(.not.allocated(iBufferR_P))then
          allocate(iBufferR_P(0:nProc-1), iBufferS_P(0:nProc-1))
          allocate(iRequestR_I(nProc-1), iRequestS_I(nProc-1))
          allocate(iStatus_II(MPI_STATUS_SIZE,nProc-1))
       end if
       ! Upper estimate of the number of variables sent 
       ! from one block to another. Used for dynamic pointer buffers.
       DnBuffer = nVar*nFaceCell

    end if

    if(nProc>1)then
       ! initialize buffer indexes
       iBufferR_P = 0
       iBufferS_P = 0
    end if

    ! Loop through all blocks
    do iBlock = 1, nBlock

       if(Unused_B(iBlock)) CYCLE

       iNode = iNode_B(iBlock)

       if(present(MinLevelSendIn) .and. .not. UseTimeLevel)then
          ! Do not send or receive below MinLevelSendIn-1 grid level
          if(iTree_IA(Level_,iNode) < MinLevelSendIn - 1) CYCLE
       end if

       do iDim = 1, nDim

          do iDimSide = 1, 2

             ! Opposite side will receive the fluxes
             iRecvSide = 3 - iDimSide

             ! Set direction indexes
             iSign = 2*iDimSide - 3
             iDir = iSign*i_DD(iDim,1)
             jDir = iSign*i_DD(iDim,2)
             kDir = iSign*i_DD(iDim,3)

             ! Check for resolution change
             DiLevel = DiLevelNei_IIIB(iDir,jDir,kDir,iBlock)

             ! For res. change send flux from fine side to coarse side
             if(DoResChangeOnly .and. DiLevel == 0) CYCLE

             ! Do not pass faces at the axis
             if(IsCylindricalAxis .and. iDim == 1 .and. iDimSide == 1 .and. &
                  iTree_IA(Coord1_,iNode) == 1) CYCLE

             if(IsSphericalAxis .and. iDim == 2)then
                if(iDimSide==1 .and. CoordMin_DB(Theta_,iBlock) < 1e-8)CYCLE
                if(iDimSide==2 .and. CoordMax_DB(Theta_,iBlock)>cPi-1e-8)CYCLE
             end if

             if(IsLatitudeAxis .and. iDim == 3)then
                if(iDimSide==1 .and. CoordMin_DB(Lat_,iBlock)<-cHalfPi+1e-8)&
                     CYCLE
                if(iDimSide==2 .and. CoordMax_DB(Lat_,iBlock)> cHalfPi-1e-8)&
                     CYCLE
             end if

             if(DiLevel == 0)then
                call do_equal
             elseif(DiLevel == 1)then
                if(present(MinLevelSendIn))then
                   ! Do not send below MinLevelSendIn
                   if(UseTimeLevel)then
                      if(iTimeLevel_A(iNode) < MinLevelSendIn) CYCLE
                   else
                      if(iTree_IA(Level_,iNode) < MinLevelSendIn) CYCLE
                   end if
                end if
                call do_restrict
             elseif(DiLevel == -1 .and. nProc > 1)then
                ! Set the buffer size for the coarse block
                call do_receive
             endif

          end do ! iDimSide
       end do ! iDim
    end do ! iBlock

    ! Done for serial run
    if(nProc == 1) RETURN

    call timing_start('send_recv')

    ! Make sure the receive buffer is large enough
    if(maxval(iBufferR_P) > MaxBufferR) call extend_buffer(&
         .false., MaxBufferR, 2*maxval(iBufferR_P), BufferR_IP)

    ! post requests
    iRequestR = 0
    do iProcSend = 0, nProc - 1
       if(DoTest) write(*,*) NameSub, ': recv iProc, iProcSend, size=',&
            iProc, iProcSend, iBufferR_P(iProcSend)

       if(iBufferR_P(iProcSend) == 0) CYCLE
       iRequestR = iRequestR + 1

       call MPI_irecv(BufferR_IP(1,iProcSend), iBufferR_P(iProcSend), &
            MPI_REAL, iProcSend, 20, iComm, iRequestR_I(iRequestR), iError)
    end do

    ! post sends
    iRequestS = 0
    do iProcRecv = 0, nProc-1
       if(DoTest) write(*,*) NameSub, ': send iProc, iProcRecv, size=',&
            iProc, iProcRecv, iBufferS_P(iProcRecv)

       if(iBufferS_P(iProcRecv) == 0) CYCLE
       iRequestS = iRequestS + 1

       call MPI_isend(BufferS_IP(1,iProcRecv), iBufferS_P(iProcRecv), &
            MPI_REAL, iProcRecv, 20, iComm, iRequestS_I(iRequestS), iError)

    end do

    ! wait for all requests to be completed
    if(iRequestR > 0) &
         call MPI_waitall(iRequestR, iRequestR_I, iStatus_II, iError)

    ! wait for all sends to be completed
    if(iRequestS > 0) &
         call MPI_waitall(iRequestS, iRequestS_I, iStatus_II, iError)

    call timing_stop('send_recv')

    call timing_start('buffer_to_flux')
    call buffer_to_flux
    call timing_stop('buffer_to_flux')

  contains

    subroutine extend_buffer(DoCopy, MaxBufferOld, MaxBufferNew, Buffer_IP)

      logical, intent(in)   :: DoCopy
      integer, intent(in)   :: MaxBufferNew
      integer, intent(inout):: MaxBufferOld
      real, pointer:: Buffer_IP(:,:)

      real, pointer :: OldBuffer_IP(:,:)
      !------------------------------------------------------------------------

      if(MaxBufferOld < 0 .or. .not.DoCopy)then
         if(MaxBufferOld > 0) deallocate(Buffer_IP)
         allocate(Buffer_IP(MaxBufferNew,0:nProc-1))
      else
         ! store old values
         OldBuffer_IP => Buffer_IP
         ! allocate extended buffer
         allocate(Buffer_IP(MaxBufferNew,0:nProc-1))
         ! copy old values
         Buffer_IP(1:MaxBufferOld,:) = OldBuffer_IP(1:MaxBufferOld,:)  
         ! free old storage
         deallocate(OldBuffer_IP)
      end if
      ! Set new buffer size
      MaxBufferOld = MaxBufferNew

    end subroutine extend_buffer

    !==========================================================================
    subroutine buffer_to_flux

      ! Copy buffer into Flux_V*B

      integer:: iBufferR, iTag, iDim, iDimSide, iSubFace1, iSubFace2, i, j, k
      !------------------------------------------------------------------------

      do iProcSend = 0, nProc - 1
         if(iBufferR_P(iProcSend) == 0) CYCLE

         iBufferR = 0
         do
            ! Read the tag from the buffer
            iTag = nint(BufferR_IP(iBufferR+1,iProcSend))
            iBufferR = iBufferR + 1

            ! Decode iTag = 100*iBlockRecv + 20*iDim + 10*(iDimSide-1) 
            !               + 3*iSubFace1 + iSubFace2
            iBlockRecv = iTag/100; iTag = iTag - 100*iBlockRecv
            iDim       = iTag/20;  iTag = iTag - 20*iDim
            iDimSide   = iTag/10;  iTag = iTag - 10*iDimSide
            iDimSide   = iDimSide + 1
            iSubFace1  = iTag/3;   iTag = iTag - 3*iSubFace1
            iSubFace2  = iTag

            select case(iDim)
            case(1)
               ! Get transverse index ranges for the (sub)face
               jRMin = iReceive_DII(2,iSubFace1,Min_)
               jRMax = iReceive_DII(2,iSubFace1,Max_)
               kRMin = iReceive_DII(3,iSubFace2,Min_)
               kRMax = iReceive_DII(3,iSubFace2,Max_)

               if(DoSubtract)then
                  ! Subtract sent flux from the original
                  do k = kRMin, kRmax; do j = jRMin, jRMax
                     Flux_VXB(:,j,k,iDimSide,iBlockRecv) = &
                          Flux_VXB(:,j,k,iDimSide,iBlockRecv) &
                          - BufferR_IP(iBufferR+1:iBufferR+nVar,iProcSend)
                     iBufferR = iBufferR + nVar
                  end do; end do
               else
                  ! Replace original flux with sum of sent flux
                  do k = kRMin, kRmax; do j = jRMin, jRMax
                     Flux_VXB(:,j,k,iDimSide,iBlockRecv) = &
                          BufferR_IP(iBufferR+1:iBufferR+nVar,iProcSend)
                     iBufferR = iBufferR + nVar
                  end do; end do
               end if

            case(2)
               iRMin = iReceive_DII(1,iSubFace1,Min_)
               iRMax = iReceive_DII(1,iSubFace1,Max_)
               kRMin = iReceive_DII(3,iSubFace2,Min_)
               kRMax = iReceive_DII(3,iSubFace2,Max_)

               if(DoSubtract)then
                  do k = kRMin, kRmax; do i = iRMin, iRMax
                     Flux_VYB(:,i,k,iDimSide,iBlockRecv) = &
                          Flux_VYB(:,i,k,iDimSide,iBlockRecv) &
                          - BufferR_IP(iBufferR+1:iBufferR+nVar,iProcSend)
                     iBufferR = iBufferR + nVar
                  end do; end do
               else
                  do k = kRMin, kRmax; do i = iRMin, iRMax
                     Flux_VYB(:,i,k,iDimSide,iBlockRecv) = &
                          BufferR_IP(iBufferR+1:iBufferR+nVar,iProcSend)
                     iBufferR = iBufferR + nVar
                  end do; end do
               end if
            case(3)
               iRMin = iReceive_DII(1,iSubFace1,Min_)
               iRMax = iReceive_DII(1,iSubFace1,Max_)
               jRMin = iReceive_DII(2,iSubFace2,Min_)
               jRMax = iReceive_DII(2,iSubFace2,Max_)

               if(DoSubtract)then
                  do j = jRMin, jRmax; do i = iRMin, iRMax
                     Flux_VZB(:,i,j,iDimSide,iBlockRecv) = &
                          Flux_VZB(:,i,j,iDimSide,iBlockRecv) &
                          - BufferR_IP(iBufferR+1:iBufferR+nVar,iProcSend)
                     iBufferR = iBufferR + nVar
                  end do; end do
               else
                  do j = jRMin, jRmax; do i = iRMin, iRMax
                     Flux_VZB(:,i,j,iDimSide,iBlockRecv) = &
                          BufferR_IP(iBufferR+1:iBufferR+nVar,iProcSend)
                     iBufferR = iBufferR + nVar
                  end do; end do
               end if
            end select

            if(iBufferR >= iBufferR_P(iProcSend)) EXIT

         end do
      end do

    end subroutine buffer_to_flux
    !==========================================================================
    subroutine do_equal

      integer:: iTimeLevel, iTimeLevelNei, nSize
      !------------------------------------------------------------------------

      ! Convert iDir,jDir,kDir = -1,0,1 into iSend,jSend,kSend = 0,1,3
      iSend = (3*iDir + 3)/2
      jSend = (3*jDir + 3)/2
      kSend = (3*kDir + 3)/2
      
      iNodeRecv  = iNodeNei_IIIB(iSend,jSend,kSend,iBlock)

      iTimeLevel    = iTimeLevel_A(iNode)
      iTimeLevelNei = iTimeLevel_A(iNodeRecv)

      ! Check if the time levels are different
      if(iTimeLevel == iTimeLevelNei) RETURN

      if(present(MinLevelSendIn))then
         ! If both time levels are below MinLevel then there is nothing to do
         if(iTimeLevel < MinLevelSendIn-1 .or. iTimeLevelNei < MinLevelSendIn-1) &
              RETURN
      end if

      iProcRecv  = iTree_IA(Proc_,iNodeRecv)
      iBlockRecv = iTree_IA(Block_,iNodeRecv)

      ! For part steady/implicit schemes
      if(Unused_BP(iBlockRecv,iProcRecv)) RETURN

      if(iTimeLevel_A(iNode) > iTimeLevel_A(iNodeRecv))then
         ! modify fluxes. Send 1 for Dn1 and Dn2 arguments (equal resolution)
         ! The iSide1, iSide2 arguments are ignored (sending 0)
         select case(iDim)
         case(1)
            call do_flux(2, 3, nJ, nK, 1, 1, 0, 0, Flux_VXB)
         case(2)
            call do_flux(1, 3, nI, nK, 1, 1, 0, 0, Flux_VYB)
         case(3)
            call do_flux(1, 2, nI, nJ, 1, 1, 0, 0, Flux_VZB)
         end select
      elseif(iProc /= iProcRecv)then
         ! Add the size of the face + the tag to the recv buffer
         ! In this case "iNodeRecv" is the sender (!)
         select case(iDim)
         case(1)
            nSize = nVar*nJ*nK
         case(2)
            nSize = nVar*nI*nK
         case(3)
            nSize = nVar*nI*nJ
         end select
         iBufferR_P(iProcRecv) = iBufferR_P(iProcRecv) + 1 + nSize
      end if

    end subroutine do_equal
    !==========================================================================
    subroutine do_restrict

      !------------------------------------------------------------------------

      ! The coordinate parity of the sender block tells 
      ! if the receiver block fills into the 
      ! lower or upper part of the face

      iSide = 0; if(iRatio==2) iSide = modulo(iTree_IA(Coord1_,iNode)-1, 2)
      jSide = 0; if(jRatio==2) jSide = modulo(iTree_IA(Coord2_,iNode)-1, 2)
      kSide = 0; if(kRatio==2) kSide = modulo(iTree_IA(Coord3_,iNode)-1, 2)

      iSend = (3*iDir + 3 + iSide)/2
      jSend = (3*jDir + 3 + jSide)/2
      kSend = (3*kDir + 3 + kSide)/2

      iNodeRecv  = iNodeNei_IIIB(iSend,jSend,kSend,iBlock)
      iProcRecv  = iTree_IA(Proc_,iNodeRecv)
      iBlockRecv = iTree_IA(Block_,iNodeRecv)

      ! For part steady/implicit schemes
      if(Unused_BP(iBlockRecv,iProcRecv)) RETURN

      select case(iDim)
      case(1)
         call do_flux(2, 3, nJ, nK, jRatio, kRatio, jSide, kSide, Flux_VXB)
      case(2)
         call do_flux(1, 3, nI, nK, iRatio, kRatio, iSide, kSide, Flux_VYB)
      case(3)
         call do_flux(1, 2, nI, nJ, iRatio, jRatio, iSide, jSide, Flux_VZB)
      end select

    end subroutine do_restrict
    !=======================================================================
    subroutine do_flux(iDim1, iDim2, n1, n2, Dn1, Dn2, iSide1, iSide2, &
         Flux_VFB)

      ! Modify fluxes on the n1 x n2 size face along dimensions iDim1,iDim2.

      ! For Dn1=1 set iSubFace1=0 (full face) and ignore iSide1.
      ! For Dn1=2 set iSubFace1=1+iSide1 where iSide1=0/1 for lower/upper
      ! For Dn2=1 set iSubFace2=0 (full face) and ignore iSide2.
      ! For Dn2=2 set iSubFace2=1+iSide2 where iSide2=0/1 for lower/upper
      
      integer, intent(in):: iDim1, iDim2, n1, n2, Dn1, Dn2, iSide1, iSide2
      real, intent(inout):: Flux_VFB(nVar,n1,n2,2,MaxBlock)

      integer:: iSubFace1, iSubFace2
      integer:: iR1, iR1Min, iR1Max, iR2, iR2Min, iR2Max
      integer:: iS1Min, iS1Max, iS2Min, iS2Max
      integer:: iVar, iBufferS
      !---------------------------------------------------------------------

      iSubFace1 = (1 + iSide1)*(Dn1 - 1)
      iSubFace2 = (1 + iSide2)*(Dn2 - 1)

      ! Receiving range depends on subface indexes
      iR1Min = iReceive_DII(iDim1,iSubFace1,Min_)
      iR1Max = iReceive_DII(iDim1,iSubFace1,Max_)
      iR2Min = iReceive_DII(iDim2,iSubFace2,Min_)
      iR2Max = iReceive_DII(iDim2,iSubFace2,Max_)

      if(iProc == iProcRecv)then

         ! Direct copy
         do iR2 = iR2Min, iR2Max
            iS2Min = 1 + Dn2*(iR2-iR2Min)
            iS2Max = iS2Min + Dn2 - 1
            do iR1 = iR1Min, iR1Max
               iS1Min = 1 + Dn1*(iR1-iR1Min)
               iS1Max = iS1Min + Dn1 - 1
               if(DoSubtract)then
                  ! Subtract sum of fine fluxes from original
                  do iVar = 1, nVar
                     Flux_VFB(iVar,iR1,iR2,iRecvSide,iBlockRecv) = &
                          Flux_VFB(iVar,iR1,iR2,iRecvSide,iBlockRecv) - &
                          sum(Flux_VFB(iVar,iS1Min:iS1Max,iS2Min:iS2Max,&
                          iDimSide,iBlock))
                  end do
               else
                  ! Replace original with sum of fine fluxes
                  do iVar = 1, nVar
                     Flux_VFB(iVar,iR1,iR2,iRecvSide,iBlockRecv) = &
                          sum(Flux_VFB(iVar,iS1Min:iS1Max,iS2Min:iS2Max,&
                          iDimSide,iBlock))
                  end do
               end if
            end do
         end do

      else

         ! Send via buffer
         iBufferS = iBufferS_P(iProcRecv)

         if(iBufferS + DnBuffer > MaxBufferS) call extend_buffer( &
              .true., MaxBufferS, 2*(iBufferS+DnBuffer), BufferS_IP)

         ! Encode all necessary info into a single "tag"
         BufferS_IP(iBufferS+1,iProcRecv) = &
              100*iBlockRecv + 20*iDim + 10*(iRecvSide-1) &
              + 3*iSubFace1 + iSubFace2

         iBufferS = iBufferS + 1

         do iR2 = iR2Min, iR2Max
            iS2Min = 1 + Dn2*(iR2-iR2Min)
            iS2Max = iS2Min + Dn2 - 1
            do iR1 = iR1Min, iR1Max
               iS1Min = 1 + Dn1*(iR1-iR1Min)
               iS1Max = iS1Min + Dn1 - 1
               do iVar = 1, nVar
                  BufferS_IP(iBufferS+iVar,iProcRecv) = &
                       sum(Flux_VFB(iVar,iS1Min:iS1Max,iS2Min:iS2Max,&
                       iDimSide,iBlock))
               end do
               iBufferS = iBufferS + nVar
            end do
         end do
         iBufferS_P(iProcRecv) = iBufferS

      end if

      ! Zero out the flux that was just sent/copied
      Flux_VFB(:,:,:,iDimSide,iBlock) = 0.0

    end subroutine do_flux

    !==========================================================================

    subroutine do_receive

      integer :: nSize
      !------------------------------------------------------------------------

      ! Loop through the subfaces
      do kSide = (1-kDir)/2, 1-(1+kDir)/2, 3-kRatio
         kSend = (3*kDir + 3 + kSide)/2
         do jSide = (1-jDir)/2, 1-(1+jDir)/2, 3-jRatio
            jSend = (3*jDir + 3 + jSide)/2
            do iSide = (1-iDir)/2, 1-(1+iDir)/2, 3-iRatio
               iSend = (3*iDir + 3 + iSide)/2

               iNodeRecv  = iNodeNei_IIIB(iSend,jSend,kSend,iBlock)

               if(UseTimeLevel .and. present(MinLevelSendIn))then
                  if(iTree_IA(Level_,iNodeRecv) < MinLevelSendIn) CYCLE
               end if

               iProcRecv  = iTree_IA(Proc_,iNodeRecv)
               iBlockRecv = iTree_IA(Block_,iNodeRecv)

               ! For part steady/implicit schemes
               if(Unused_BP(iBlockRecv,iProcRecv)) CYCLE

               ! Same processor gets direct copy
               if(iProc == iProcRecv) CYCLE

               ! Calculate size of the face
               select case(iDim)
               case(1)
                  nSize = nVar*nJ*nK/(jRatio*kRatio)
               case(2)
                  nSize = nVar*nI*nK/(iRatio*kRatio)
               case(3)
                  nSize = nVar*nI*nJ/(iRatio*jRatio)
               end select
               iBufferR_P(iProcRecv) = iBufferR_P(iProcRecv) + 1 + nSize

            end do
         end do
      end do

    end subroutine do_receive

    !==========================================================================

    subroutine set_range

      integer:: iDim

      do iDim = 1, MaxDim
         ! Full face
         iReceive_DII(iDim,0,Min_) = 1
         iReceive_DII(iDim,0,Max_) = nIjk_D(iDim)

         ! Lower subface
         iReceive_DII(iDim,1,Min_) = 1
         iReceive_DII(iDim,1,Max_) = nIjk_D(iDim)/2

         ! Upper subface
         iReceive_DII(iDim,2,Min_) = nIjk_D(iDim)/2 + 1
         iReceive_DII(iDim,2,Max_) = nIjk_D(iDim)
      end do

    end subroutine set_range

  end subroutine message_pass_face

  !============================================================================

  subroutine store_face_flux(iBlock, nVar, Flux_VFD, &
               Flux_VXB, Flux_VYB, Flux_VZB, &
               DtIn, DoResChangeOnlyIn, DoStoreCoarseFluxIn)

    ! Put Flux_VFD into Flux_VXB, Flux_VYB, Flux_VZB for the appropriate faces.
    ! The coarse face flux is also stored unless DoStoreCoarseFluxIn is false.
    ! Multiply flux by DtIn if present and add to previously stored flux 
    ! so there is a time integral for subcycling.

    use BATL_size, ONLY: nDim, nI, nJ, nK, MaxBlock
    use BATL_tree, ONLY: DiLevelNei_IIIB

    integer, intent(in):: iBlock, nVar
    real, intent(in):: Flux_VFD(nVar,nI+1,nJ+1,nK+1,nDim)
    real, intent(inout), optional:: &
         Flux_VXB(nVar,nJ,nK,2,MaxBlock), &
         Flux_VYB(nVar,nI,nK,2,MaxBlock), &
         Flux_VZB(nVar,nI,nJ,2,MaxBlock)

    real, intent(in), optional:: DtIn

    logical, intent(in), optional:: &
         DoResChangeOnlyIn, &
         DoStoreCoarseFluxIn

    real :: Dt
    logical::  DoResChangeOnly, DoStoreCoarseFlux
    integer:: DiLevel
    !--------------------------------------------------------------------------
    ! Store flux at resolution change for conservation fix

    Dt = 1.0
    if(present(DtIn)) Dt = DtIn
    DoResChangeOnly = .true.
    if(present(DoResChangeOnlyIn)) DoResChangeOnly = DoResChangeOnlyIn
    DoStoreCoarseFlux = .true.
    if(present(DoStoreCoarseFluxIn)) DoStoreCoarseFlux = DoStoreCoarseFluxIn

    if(present(Flux_VXB))then
       DiLevel = DiLevelNei_IIIB(-1,0,0,iBlock)
       if(.not. DoResChangeOnly .or. DiLevel == 1 &
            .or. DiLevel == -1 .and. DoStoreCoarseFlux) &
            Flux_VXB(:,1:nJ,1:nK,1,iBlock) = Flux_VXB(:,1:nJ,1:nK,1,iBlock) &
            + Dt*Flux_VFD(:,1,1:nJ,1:nK,1)

       DiLevel = DiLevelNei_IIIB(+1,0,0,iBlock)
       if(.not. DoResChangeOnly .or. DiLevel == 1 &
            .or. DiLevel == -1 .and. DoStoreCoarseFlux) &
            Flux_VXB(:,1:nJ,1:nK,2,iBlock) = Flux_VXB(:,1:nJ,1:nK,2,iBlock) &
            + Dt*Flux_VFD(:,nI+1,1:nJ,1:nK,1)
    end if

    if(present(Flux_VYB) .and. nDim > 1)then
       DiLevel = DiLevelNei_IIIB(0,-1,0,iBlock)
       if(.not. DoResChangeOnly .or. DiLevel == 1 &
            .or. DiLevel == -1 .and. DoStoreCoarseFlux) &
            Flux_VYB(:,1:nI,1:nK,1,iBlock) = Flux_VYB(:,1:nI,1:nK,1,iBlock) &
            + Dt*Flux_VFD(:,1:nI,1,1:nK,min(2,nDim))
       
       DiLevel = DiLevelNei_IIIB(0,+1,0,iBlock)
       if(.not. DoResChangeOnly .or. DiLevel == 1 &
            .or. DiLevel == -1 .and. DoStoreCoarseFlux) &
            Flux_VYB(:,1:nI,1:nK,2,iBlock) = Flux_VYB(:,1:nI,1:nK,2,iBlock) &
            + Dt*Flux_VFD(:,1:nI,nJ+1,1:nK,min(2,nDim))
    end if

    if(present(Flux_VZB) .and. nDim > 2)then
       DiLevel = DiLevelNei_IIIB(0,0,-1,iBlock)
       if(.not. DoResChangeOnly .or. DiLevel == 1 &
            .or. DiLevel == -1 .and. DoStoreCoarseFlux) &
            Flux_VZB(:,1:nI,1:nJ,1,iBlock) = Flux_VZB(:,1:nI,1:nJ,1,iBlock) &
            + Dt*Flux_VFD(:,1:nI,1:nJ,1,nDim)

       DiLevel = DiLevelNei_IIIB(0,0,+1,iBlock)
       if(.not. DoResChangeOnly .or. DiLevel == 1 &
            .or. DiLevel == -1 .and. DoStoreCoarseFlux) &
            Flux_VZB(:,1:nI,1:nJ,2,iBlock) = Flux_VZB(:,1:nI,1:nJ,2,iBlock) &
            + Dt*Flux_VFD(:,1:nI,1:nJ,nK+1,nDim)
    end if

  end subroutine store_face_flux

  !============================================================================

  subroutine correct_face_flux(iBlock, nVar, &
    Flux_VXB, Flux_VYB, Flux_VZB, Flux_VFD)

    ! Put Flux_VXB, Flux_VYB, Flux_VZB after message_pass_face
    ! back into Flux_VFDB into for the appropriate faces.

    use BATL_size, ONLY: nDim, nI, nJ, nK, MaxBlock
    use BATL_tree, ONLY: DiLevelNei_IIIB

    integer, intent(in):: iBlock, nVar

    real, intent(in), optional:: &
         Flux_VXB(nVar,nJ,nK,2,MaxBlock), &
         Flux_VYB(nVar,nI,nK,2,MaxBlock), &
         Flux_VZB(nVar,nI,nJ,2,MaxBlock)

    real, intent(inout):: Flux_VFD(nVar,nI+1,nJ+1,nK+1,nDim)
    !--------------------------------------------------------------------------
    ! Store flux at resolution change for conservation fix

    if(present(Flux_VXB))then
       if(DiLevelNei_IIIB(-1,0,0,iBlock) == -1) &
            Flux_VFD(:,1,1:nJ,1:nK,1) = Flux_VXB(:,1:nJ,1:nK,1,iBlock)

       if(DiLevelNei_IIIB(+1,0,0,iBlock) == -1) &
            Flux_VFD(:,nI+1,1:nJ,1:nK,1) = Flux_VXB(:,1:nJ,1:nK,2,iBlock)
    end if

    ! min(2,nDim) avoids compiler complaints when nDim is 1
    if(present(Flux_VYB) .and. nDim > 1)then
       if(DiLevelNei_IIIB(0,-1,0,iBlock) == -1) &
            Flux_VFD(:,1:nI,1,1:nK,min(2,nDim)) &
            = Flux_VYB(:,1:nI,1:nK,1,iBlock)
       
       if(DiLevelNei_IIIB(0,+1,0,iBlock) == -1) &
            Flux_VFD(:,1:nI,nJ+1,1:nK,min(2,nDim)) &
            = Flux_VYB(:,1:nI,1:nK,2,iBlock)
    end if

    if(present(Flux_VZB) .and. nDim > 2)then
       if(DiLevelNei_IIIB(0,0,-1,iBlock) == -1) &
            Flux_VFD(:,1:nI,1:nJ,1,nDim) = Flux_VZB(:,1:nI,1:nJ,1,iBlock) 

       if(DiLevelNei_IIIB(0,0,+1,iBlock) == -1) &
            Flux_VFD(:,1:nI,1:nJ,nK+1,nDim) = Flux_VZB(:,1:nI,1:nJ,2,iBlock)
    end if

  end subroutine correct_face_flux

  !============================================================================

  subroutine apply_flux_correction(nVar, nFluid, State_VGB, Energy_GBI,&
       Flux_VXB, Flux_VYB, Flux_VZB, DoResChangeOnlyIn, iStageIn)

    ! Correct State_VGB based on the flux differences stored in
    ! Flux_VXB, Flux_VYB and Flux_VZB.

    use BATL_size, ONLY: nI, nJ, nK, nG, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
         MaxBlock, nBlock
    use BATL_tree, ONLY: nLevelMax, Unused_B, iNode_B, iTree_IA, Level_, &
         UseTimeLevel, nTimeLevel, iTimeLevel_A

    integer, intent(in):: nVar, nFluid
    real, intent(inout):: &
         State_VGB(nVar,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock)
    real, intent(inout), optional:: &
         Energy_GBI(MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock,nFluid)
    real, intent(inout), optional:: &
         Flux_VXB(nVar+nFluid,nJ,nK,2,MaxBlock), &
         Flux_VYB(nVar+nFluid,nI,nK,2,MaxBlock), &
         Flux_VZB(nVar+nFluid,nI,nJ,2,MaxBlock)
    logical, intent(in), optional:: DoResChangeOnlyIn
    integer, intent(in), optional:: iStageIn

    integer:: iBlock, iNode, iLevel, iStage, MinLevelSend, MaxLevel
    !-------------------------------------------------------------------------
    ! Set the levels MinLevelSend .. nLevelMax which need to send fluxes
    ! If iStageIn is a multiple of 2^p then the finest p levels should 
    ! send fluxes. 
    if(UseTimeLevel)then
       MaxLevel = nTimeLevel
    else
       MaxLevel = nLevelmax
    end if

    if(present(iStageIn))then
       MinLevelSend = MaxLevel + 1
       iStage = iStageIn
       do
          ! Check if iStage is still an even number
          if(modulo(iStage,2) == 1)EXIT
          ! Remove 2 factor from iStage and add another level for sending flux
          iStage = iStage/2
          MinLevelSend = MinLevelSend - 1
       end do
    else
       MinLevelSend = 1
    end if

    call message_pass_face(nVar+nFluid, Flux_VXB, Flux_VYB, Flux_VZB, &
         DoResChangeOnlyIn=DoResChangeOnlyIn, MinLevelSendIn = MinLevelSend)

    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE
       iNode = iNode_B(iBlock)
       if(UseTimeLevel)then
          iLevel = iTimeLevel_A(iNode)
       else
          iLevel = iTree_IA(Level_,iNode)
       end if
       ! highest level should never be corrected
       if(iLevel == MaxLevel) CYCLE
       if(present(iStageIn))then
          ! Check if this block should receive any flux correction
          if(iLevel < MinLevelSend - 1) CYCLE
       end if

       if(present(Energy_GBI))then
          call apply_flux_correction_block(iBlock, nVar, nFluid, nG, &
               State_VGB(:,:,:,:,iBlock), &
               Energy_GI=Energy_GBI(:,:,:,iBlock,:), &
               Flux_VXB=Flux_VXB, Flux_VYB=Flux_VYB, Flux_VZB=Flux_VZB, &
               DoResChangeOnlyIn=DoResChangeOnlyIn)
       else
          call apply_flux_correction_block(iBlock, nVar, nFluid, nG, &
               State_VGB(:,:,:,:,iBlock), &
               Flux_VXB=Flux_VXB, Flux_VYB=Flux_VYB, Flux_VZB=Flux_VZB, &
               DoResChangeOnlyIn=DoResChangeOnlyIn)
       end if
    end do

  end subroutine apply_flux_correction

  !============================================================================

  subroutine apply_flux_correction_block(iBlock, nVar, nFluid, nG, &
       State_VG, Energy_GI, Flux_VXB, Flux_VYB, Flux_VZB, DoResChangeOnlyIn)

    ! Put Flux_VXB, Flux_VYB, Flux_VZB into State_VGB for the appropriate faces

    use BATL_size, ONLY: nI, nJ, nK, jDim_, kDim_, MaxBlock
    use BATL_tree, ONLY: di_level_nei
    use BATL_geometry, ONLY: IsCartesian
    use BATL_grid, ONLY: CellVolume_B, CellVolume_GB

    integer, intent(in):: iBlock, nVar, nG, nFluid
    ! The min and max functions are needed for 1D and 2D.
    real, intent(inout):: State_VG(nVar, 1-nG:nI+nG, &
         1-nG*jDim_:nJ+nG*jDim_, 1-nG*kDim_:nK+nG*kDim_)
    real, intent(inout), optional:: Energy_GI(1-nG:nI+nG, &
         1-nG*jDim_:nJ+nG*jDim_, 1-nG*kDim_:nK+nG*kDim_, nFluid)
    real, intent(inout), optional:: &
         Flux_VXB(nVar+nFluid,nJ,nK,2,MaxBlock), &
         Flux_VYB(nVar+nFluid,nI,nK,2,MaxBlock), &
         Flux_VZB(nVar+nFluid,nI,nJ,2,MaxBlock)
    logical, intent(in), optional:: DoResChangeOnlyIn

    logical:: DoResChangeOnly
    real:: InvVolume
    integer:: i, j, k
    integer:: nFlux
    !--------------------------------------------------------------------------

    nFlux = nVar + nFluid

    DoResChangeOnly = .true.
    if(present(DoResChangeOnlyIn)) DoResChangeOnly = DoResChangeOnlyIn

    if(IsCartesian) InvVolume = 1.0/CellVolume_B(iBlock)

    if(di_level_nei(-1,0,0,iBlock,DoResChangeOnly)==-1)then
       do k = 1, nK; do j = 1, nJ
          if(.not.IsCartesian) InvVolume = 1.0/CellVolume_GB(1,j,k,iBlock)
          State_VG(:,1,j,k) = State_VG(:,1,j,k) &
               - InvVolume*Flux_VXB(1:nVar,j,k,1,iBlock)
          if(present(Energy_GI)) Energy_GI(1,j,k,:) = Energy_GI(1,j,k,:) &
               - InvVolume*Flux_VXB(nVar+1:nFlux,j,k,1,iBlock)
       end do; end do
       Flux_VXB(:,:,:,1,iBlock) = 0.0
    end if

    if(di_level_nei(+1,0,0,iBlock,DoResChangeOnly)==-1)then
       do k = 1, nK; do j = 1, nJ
          if(.not.IsCartesian) InvVolume = 1.0/CellVolume_GB(nI,j,k,iBlock)
          State_VG(:,nI,j,k) = State_VG(:,nI,j,k) &
               + InvVolume*Flux_VXB(1:nVar,j,k,2,iBlock)
          if(present(Energy_GI)) Energy_GI(nI,j,k,:) = Energy_GI(nI,j,k,:) &
               + InvVolume*Flux_VXB(nVar+1:nFlux,j,k,2,iBlock)
       end do; end do
       Flux_VXB(:,:,:,2,iBlock) = 0.0
    end if

    if(di_level_nei(0,-1,0,iBlock,DoResChangeOnly)==-1)then
       do k = 1, nK; do i = 1, nI
          if(.not.IsCartesian) InvVolume = 1.0/CellVolume_GB(i,1,k,iBlock)
          State_VG(:,i,1,k) = State_VG(:,i,1,k) &
               - InvVolume*Flux_VYB(1:nVar,i,k,1,iBlock)
          if(present(Energy_GI)) Energy_GI(i,1,k,:) = Energy_GI(i,1,k,:) &
               - InvVolume*Flux_VYB(nVar+1:nFlux,i,k,1,iBlock)

       end do; end do
       Flux_VYB(:,:,:,1,iBlock) = 0.0
    end if

    if(di_level_nei(0,+1,0,iBlock,DoResChangeOnly)==-1)then
       do k = 1, nK; do i = 1, nI
          if(.not.IsCartesian) InvVolume = 1.0/CellVolume_GB(i,nJ,k,iBlock)
          State_VG(:,i,nJ,k) = State_VG(:,i,nJ,k) &
               + InvVolume*Flux_VYB(1:nVar,i,k,2,iBlock)
          if(present(Energy_GI)) Energy_GI(i,nJ,k, :) = Energy_GI(i,nJ,k, :) &
               + InvVolume*Flux_VYB(nVar+1:nFlux,i,k,2,iBlock)
       end do; end do
       Flux_VYB(:,:,:,2,iBlock) = 0.0
    end if

    if(di_level_nei(0,0,-1,iBlock,DoResChangeOnly)==-1)then
       do j = 1, nJ; do i = 1, nI
          if(.not.IsCartesian) InvVolume = 1.0/CellVolume_GB(i,j,1,iBlock)
          State_VG(:,i,j,1) = State_VG(:,i,j,1) &
               - InvVolume*Flux_VZB(1:nVar,i,j,1,iBlock)
          if(present(Energy_GI)) Energy_GI(i,j,1, :) = Energy_GI(i,j,1, :) &
               - InvVolume*Flux_VZB(nVar+1:nFlux,i,j,1,iBlock)
       end do; end do
       Flux_VZB(:,:,:,1,iBlock) = 0.0
    end if

    if(di_level_nei(0,0,+1,iBlock,DoResChangeOnly)==-1)then
       do j = 1, nJ; do i = 1, nI
          if(.not.IsCartesian) InvVolume = 1.0/CellVolume_GB(i,j,nK,iBlock)
          State_VG(:,i,j,nK) = State_VG(:,i,j,nK) &
               + InvVolume*Flux_VZB(1:nVar,i,j,2,iBlock)
          if(present(Energy_GI)) Energy_GI(i,j,nK, :) = Energy_GI(i,j,nK, :) &
               + InvVolume*Flux_VZB(nVar+1:nFlux,i,j,2,iBlock)
       end do; end do
       Flux_VZB(:,:,:,2,iBlock) = 0.0
    end if

  end subroutine apply_flux_correction_block

  !============================================================================

  subroutine test_pass_face

    use BATL_mpi,  ONLY: iProc
    use BATL_size, ONLY: MaxDim, nDim, nI, nJ, nK, nBlock
    use BATL_tree, ONLY: init_tree, set_tree_root, find_tree_node, &
         refine_tree_node, distribute_tree, show_tree, clean_tree, &
         Unused_B, UseTimeLevel, iTimeLevel_A, nNode, &
         iTree_IA, Level_, iNode_B, di_level_nei
    use BATL_grid, ONLY: init_grid, create_grid, clean_grid, &
         Xyz_DGB, CellFace_DB
    use BATL_geometry, ONLY: init_geometry

    integer, parameter:: MaxBlockTest            = 50
    integer, parameter:: nRootTest_D(MaxDim)     = (/3,3,3/)
    logical, parameter:: IsPeriodicTest_D(MaxDim)= .true.
    real, parameter:: DomainMin_D(MaxDim) = (/ 1.0, 10.0, 100.0 /)
    real, parameter:: DomainMax_D(MaxDim) = (/ 4.0, 40.0, 400.0 /)

    real, parameter:: Tolerance = 1e-6

    integer, parameter:: nVar = nDim
    real, allocatable, dimension(:,:,:,:,:):: &
         Flux_VFD, Flux_VXB, Flux_VYB, Flux_VZB

    integer:: iResChangeOnly
    logical:: DoResChangeOnly

    integer:: iNode, iBlock, i, j, k, iDim, DiLevel
    integer:: iStage, nStage, iTimeLevel
    real:: Flux, FluxGood, FluxUnset=-77.0

    logical:: DoTestMe
    character(len=*), parameter :: NameSub = 'test_pass_face'
    !-----------------------------------------------------------------------
    DoTestMe = iProc == 0

    if(DoTestMe) write(*,*) 'Starting ',NameSub

    call init_tree(MaxBlockTest)
    call init_geometry( IsPeriodicIn_D = IsPeriodicTest_D(1:nDim) )
    call init_grid( DomainMin_D(1:nDim), DomainMax_D(1:nDim) )
    call set_tree_root( nRootTest_D(1:nDim))

    call find_tree_node( (/0.5,0.5,0.5/), iNode)
    if(DoTestMe)write(*,*) NameSub,' middle node=',iNode
    call refine_tree_node(iNode)
    call distribute_tree(.true.)
    call create_grid

    allocate( &
         Flux_VFD(nVar,nI+1,nJ+1,nK+1,nDim),  &
         Flux_VXB(nVar,nJ,nK,2,MaxBlockTest), &
         Flux_VYB(nVar,nI,nK,2,MaxBlockTest), &
         Flux_VZB(nVar,nI,nJ,2,MaxBlockTest), &
         iTimeLevel_A(nNode))

    do iNode = 1, nNode
       iTimeLevel_A(iNode) = modulo(iNode,4) + 5*iTree_IA(Level_,iNode)
    end do

    if(DoTestMe) &
         call show_tree(NameSub, DoShowNei=.true.) ! DoShowTimeLevel=.true.)

    do iResChangeOnly = 1, 2

       DoResChangeOnly  = iResChangeOnly == 1
       UseTimeLevel = .not.DoResChangeOnly

       if(DoTestMe)write(*,*) 'testing message_pass_face with', &
            ' DoResChangeOnly, UseTimeLevel=',  DoResChangeOnly, UseTimeLevel

       Flux_VFD = 0.0
       Flux_VXB = 0.0
       Flux_VYB = 0.0
       Flux_VZB = 0.0

       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE

          ! Set Flux_VFD based on the coordinates
          call set_flux

          if(UseTimeLevel)then
             ! Pretend subsycling nStage times
             nStage = iTimeLevel_A(iNode_B(iBlock))
             do iStage = 1, nStage
                call store_face_flux(iBlock, nVar, Flux_VFD, &
                     Flux_VXB, Flux_VYB, Flux_VZB, &
                     DoResChangeOnlyIn = .false., &
                     DoStoreCoarseFluxIn = .true., &
                     DtIn = 1.0/nStage)
             end do
          else
             call store_face_flux(iBlock, nVar, Flux_VFD, &
                  Flux_VXB, Flux_VYB, Flux_VZB, &
                  DoResChangeOnlyIn = .true., &
                  DoStoreCoarseFluxIn = .true.)
          end if

          iTimeLevel = iTimeLevel_A(iNode_B(iBlock))

          ! Set the fluxes to the unset value except on the fine side
          if(di_level_nei(-1,0,0,iBlock,DoResChangeOnly) < 1) &
               Flux_VXB(:,:,:,1,iBlock) = FluxUnset

          if(di_level_nei(+1,0,0,iBlock,DoResChangeOnly) < 1) &
               Flux_VXB(:,:,:,2,iBlock) = FluxUnset

          if(nDim > 1)then
             if(di_level_nei(0,-1,0,iBlock,DoResChangeOnly) < 1) &
                  Flux_VYB(:,:,:,1,iBlock) = FluxUnset

             if(di_level_nei(0,+1,0,iBlock,DoResChangeOnly) < 1) &
                  Flux_VYB(:,:,:,2,iBlock) = FluxUnset

          end if

          if(nDim > 2)then
             if(di_level_nei(0,0,-1,iBlock,DoResChangeOnly) < 1) &
                  Flux_VZB(:,:,:,1,iBlock) = FluxUnset

             if(di_level_nei(0,0,+1,iBlock,DoResChangeOnly) < 1) &
                  Flux_VZB(:,:,:,2,iBlock) = FluxUnset

          end if

       end do

       ! Message pass from fine to coarse grid/time levels
       ! Zero out the fine side.
       call message_pass_face(nVar, Flux_VXB, Flux_VYB, Flux_VZB, &
            DoSubtractIn=.false., DoResChangeOnlyIn=DoResChangeOnly)

       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE

          ! Calculate the coordinate based Flux_VFD again
          call set_flux

          ! Check min X face
          DiLevel = di_level_nei(-1,0,0,iBlock,DoResChangeOnly)
          do k = 1, nK; do j = 1, nJ; do iDim = 1, nDim
             Flux = Flux_VXB(iDim,j,k,1,iBlock)
             FluxGood = flux_good(DiLevel, 1, Flux_VFD(iDim,1,j,k,1))

             if(  abs(Flux - FluxGood) > Tolerance )then
                write(*,*)'Error at min X face: ', &
                     'iNode,DiLevel,j,k,iDim,Flux,Good=', &
                     iNode_B(iBlock), DiLevel, j, k, iDim, Flux, FluxGood, &
                     CellFace_DB(1,iBlock)                
             end if
          end do; end do; end do

          ! Check max X face
          DiLevel = di_level_nei(+1,0,0,iBlock,DoResChangeOnly)
          do k = 1, nK; do j = 1, nJ; do iDim = 1, nDim
             Flux     = Flux_VXB(iDim,j,k,2,iBlock)
             FluxGood = flux_good(DiLevel, 1, Flux_VFD(iDim,nI+1,j,k,1))
             if(  abs(Flux - FluxGood) > Tolerance ) &
                  write(*,*)'Error at max X face: ', &
                  'iNode,DiLevel,j,k,iDim,Flux,Good=', &
                  iNode_B(iBlock), DiLevel, j, k, iDim, Flux, FluxGood
          end do; end do; end do

          if(nDim > 1)then
             ! Check min Y face
             DiLevel = di_level_nei(0,-1,0,iBlock,DoResChangeOnly)
             do k = 1, nK; do i = 1, nI; do iDim = 1, nDim
                Flux     = Flux_VYB(iDim,i,k,1,iBlock)
                FluxGood = flux_good(DiLevel, 2, Flux_VFD(iDim,i,1,k,2))
                if(  abs(Flux - FluxGood) > Tolerance ) &
                     write(*,*)'Error at min Y face: ', &
                     'iNode,DiLevel,i,k,iDim,Flux,Good=', &
                     iNode_B(iBlock), DiLevel, i, k, iDim, Flux, FluxGood
             end do; end do; end do

             ! Check max Y face
             DiLevel = di_level_nei(0,+1,0,iBlock,DoResChangeOnly)
             do k = 1, nK; do i = 1, nI; do iDim = 1, nDim
                Flux     = Flux_VYB(iDim,i,k,2,iBlock)
                FluxGood = flux_good(DiLevel, 2, Flux_VFD(iDim,i,nJ+1,k,2))
                if(  abs(Flux - FluxGood) > Tolerance ) &
                     write(*,*)'Error at max Y face: ', &
                     'iNode,DiLevel,i,k,iDim,Flux,Good=', &
                     iNode_B(iBlock), DiLevel, i, k, iDim, Flux, FluxGood
             end do; end do; end do
          end if

          if(nDim > 2)then
             ! Check min Z face
             DiLevel = di_level_nei(0,0,-1,iBlock,DoResChangeOnly)
             do j = 1, nJ; do i = 1, nI; do iDim = 1, nDim
                Flux     = Flux_VZB(iDim,i,j,1,iBlock)
                FluxGood = flux_good(DiLevel, 3, Flux_VFD(iDim,i,j,1,3))
                if(  abs(Flux - FluxGood) > Tolerance ) &
                     write(*,*)'Error at min Z face: ', &
                     'iNode,DiLevel,i,j,iDim,Flux,Good=', &
                     iNode_B(iBlock), DiLevel, i, j, iDim, Flux, FluxGood
             end do; end do; end do

             ! Check max Z face
             DiLevel = di_level_nei(0,0,+1,iBlock,DoResChangeOnly)
             do j = 1, nJ; do i = 1, nI; do iDim = 1, nDim
                Flux     = Flux_VZB(iDim,i,j,2,iBlock)
                FluxGood = flux_good(DiLevel, 3, Flux_VFD(iDim,i,j,nK+1,3))
                if(  abs(Flux - FluxGood) > Tolerance ) &
                     write(*,*)'Error at max Z face: ', &
                     'iNode,DiLevel,i,j,iDim,Flux,Good=', &
                     iNode_B(iBlock), DiLevel, i, j, iDim, Flux, FluxGood
             end do; end do; end do
          end if

       end do ! iBlock

    end do ! test parameters
    deallocate(Flux_VFD, Flux_VXB, Flux_VYB, Flux_VZB)

    call clean_grid
    call clean_tree

  contains
    !==========================================================================
    subroutine set_flux

      ! Fill in Flux_VFD with coordinates of the face center

      Flux_VFD(:,:,1:nJ,1:nK,1) = 0.5*CellFace_DB(1,iBlock)* &
           ( Xyz_DGB(1:nDim,0:nI  ,1:nJ,1:nK,iBlock) &
           + Xyz_DGB(1:nDim,1:nI+1,1:nJ,1:nK,iBlock) )

      if(nDim > 1) &
           Flux_VFD(:,1:nI,:,1:nK,2) = 0.5*CellFace_DB(2,iBlock)* &
           ( Xyz_DGB(1:nDim,1:nI,0:nJ  ,1:nK,iBlock) &
           + Xyz_DGB(1:nDim,1:nI,1:nJ+1,1:nK,iBlock) )

      if(nDim > 2) &
           Flux_VFD(:,1:nI,1:nJ,:,3) = 0.5*CellFace_DB(3,iBlock)* &
           ( Xyz_DGB(1:nDim,1:nI,1:nJ,0:nK  ,iBlock) &
           + Xyz_DGB(1:nDim,1:nI,1:nJ,1:nK+1,iBlock) )

    end subroutine set_flux

    !========================================================================
    real function flux_good(DiLevel, iDir, XyzCellFace)

      integer, intent(in):: DiLevel, iDir
      real,    intent(in):: XyzCellFace

      ! Calculate the correct flux solution in direction iDir based on the 
      ! grid/time level change DiLevel at the given face.
      ! The coordinate XyzCellFace is the correct answer on the coarse side.
      ! Zero is the correct value on the fine side. 
      ! FluxUnset is the correct value everywhere else.

      real:: CellFace
      !---------------------------------------------------------------------
      select case(DiLevel)
      case(0)
         flux_good = FluxUnset
      case(1)
         ! The flux is zeroed out on the fine side
         flux_good = 0.0
      case(-1)
         ! The flux is set to coordinate value on the coarse side
         flux_good = XyzCellFace

         ! Fix periodic coordinates. Flux = Coordinate*CellArea
         if(iDim == iDir)then
            CellFace = CellFace_DB(iDim,iBlock)
            if(abs(XyzCellFace/CellFace - DomainMin_D(iDim)) < Tolerance) &
                 flux_good = DomainMax_D(iDim)*CellFace
            if(abs(XyzCellFace/CellFace - DomainMax_D(iDim)) < Tolerance) &
                 flux_good = DomainMin_D(iDim)*CellFace
         endif
      case default
         call CON_stop(NameSub//' invalid value for DiLevel')
      end select

    end function flux_good

  end subroutine test_pass_face

end module BATL_pass_face
