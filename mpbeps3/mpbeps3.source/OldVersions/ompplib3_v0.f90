!-----------------------------------------------------------------------
!
      module ompplib3
!
! ompmove3 reorder particles by tile with OpenMP and MPI
!          calls mporderf3a or mporder3a, and mpmove3, mporder3b
! wmpfft3r performs 3d real/complex FFT for scalar data,
!          moving data between uniform and non-uniform partitions
!          calls mpfmove3 and mpfft3r
! wmpfft3rn performs 3d real/complex FFT for n component vector data,
!           moving data between uniform and non-uniform partitions
!           calls mpfnmove3 and mpfft3rn
! wmpcguard3 copy scalar guard cells to local and remote partitions
! wmpncguard3 copy vector guard cells to local and remote partitions
!             calls mpncguard3, mpcguard3x
! wmpaguard3 add scalar guard cells from local and remote partitions
!            calls mpaguard3x, mpnaguard3
! wmpnacguard3 add vector guard cells from local and remote partitions
!              calls mpacguard3x, mpnacguard3
! written by viktor k. decyk, ucla
! copyright 2016, regents of the university of california
! update: february 13, 2016
!
      use modmpsort3
      use modmpfft3
      use modmpgard3
      use mppmod3, only: mpmove3, mpfmove3, mpfnmove3, mpcguard3,       &
     &mpncguard3, mpnaguard3, mpnacguard3
      implicit none
!
! ppbuff = buffer array for reordering tiled particle array
      real, dimension(:,:,:), allocatable :: ppbuff
      integer :: szpbuf = 0
! sbufl/sbufr = particle buffers sent to nearby processors
! rbufl/rbufr = particle buffers received from nearby processors
      real, dimension(:,:,:), allocatable :: sbufl, sbufr, rbufl, rbufr
      integer :: szbufs = 0
! ncll/nclr/mcll/mclr = number offsets send/received from processors
      integer, dimension(:,:,:,:), allocatable :: ncll, nclr, mcll, mclr
      integer :: sznbufs = 0
! mcls = number offsets received from corner processors
      integer, dimension(:,:,:), allocatable :: mcls
      integer :: szmbufs = 0
      save
!
      private :: ppbuff, szpbuf
      private :: sbufl, sbufr, rbufl, rbufr, szbufs
      private :: ncll, nclr, mcll, mclr, mcls, sznbufs, szmbufs
!
      contains
!
!-----------------------------------------------------------------------
      subroutine ompmove3(ppart,kpic,ncl,ihole,noff,nyzp,tsort,tmov,    &
     &kstrt,nvpy,nvpz,nx,ny,nz,mx,my,mz,npbmx,nbmax,mx1,myp1,mzp1,mxzyp1&
     &,list,irc)
! reorder particles by tile with OpenMP and MPI
! list = (true,false) = list of particles leaving tiles found in push
      implicit none
      integer, intent(in) :: kstrt, nvpy, nvpz, nx, ny, nz, mx, my, mz
      integer, intent(in) :: npbmx, nbmax, mx1, myp1, mzp1, mxzyp1
      real, intent(inout) :: tsort, tmov
      integer, intent(inout) :: irc
      logical, intent(in) :: list
      real, dimension(:,:,:), intent(inout) :: ppart
      integer, dimension(:), intent(inout) :: kpic
      integer, dimension(:,:), intent(inout) :: ncl
      integer, dimension(:,:,:), intent(inout) :: ihole
      integer, dimension(:), intent(in) :: noff, nyzp
! local data
      integer :: idimp, nppmx, mxyzp1, ntmax
! extract dimensions
      idimp = size(ppart,1); nppmx = size(ppart,2)
      mxyzp1 = size(ppart,3)
      ntmax = size(ihole,2) - 1
! check if required size of buffer has increased
      if (szpbuf < idimp*npbmx*mxyzp1) then
         if (szpbuf /= 0) deallocate(ppbuff)
! allocate new buffer
         allocate(ppbuff(idimp,npbmx,mxyzp1))
         szpbuf = idimp*npbmx*mxyzp1
      endif
! check if required size of buffers has increased
      if (szbufs < idimp*nbmax*2) then
         if (szbufs /= 0) deallocate(sbufl,sbufr,rbufl,rbufr)
! allocate new buffers
         allocate(sbufl(idimp,nbmax,2),sbufr(idimp,nbmax,2))
         allocate(rbufl(idimp,nbmax,2),rbufr(idimp,nbmax,2))
         szbufs = idimp*nbmax*2
      endif
! check if required size of buffers has increased
      if (sznbufs < 3*mxzyp1*3*2) then
         if (sznbufs /= 0) deallocate(ncll,nclr,mcll,mclr)
! allocate new buffers
         allocate(ncll(3,mxzyp1,3,2),nclr(3,mxzyp1,3,2))
         allocate(mcll(3,mxzyp1,3,2),mclr(3,mxzyp1,3,2))
         sznbufs = 3*mxzyp1*3*2
      endif
! check if required size of buffer has increased
      if (szmbufs < 3*(mx1+1)*4) then
         if (szmbufs /= 0) deallocate(ncll,nclr,mcll,mclr)
! allocate new buffer
         allocate(mcls(3,mx1+1,4))
         szmbufs = 3*(mx1+1)*4
      endif
!
! first part of particle reorder on x, y, and z cell
! with mx, my, mz tiles:
! list of particles leaving tile already calculated by push
      if (list) then
! updates: ppart, ppbuff, sbufl, sbufr, ncl, ncll, nclr, irc
         call mporderf3a(ppart,ppbuff,sbufl,sbufr,ncl,ihole,ncll,nclr,  &
     &tsort,mx1,myp1,irc)
         if (irc /= 0) then
            write (*,*) kstrt,'mporderf3a error: ntmax, irc=',ntmax,irc
         endif
! calculate list of particles leaving tile
      else
! updates ppart, ppbuff, sbufl, sbufr, ncl, ihole, ncll, nclr, irc
          call mporder3a(ppart,ppbuff,sbufl,sbufr,kpic,ncl,ihole,ncll,  &
     &nclr,noff,nyzp,tsort,nx,ny,nz,mx,my,mz,mx1,myp1,irc)
         if (irc /= 0) then
            write (*,*) kstrt,'mporder3a error: ntmax, irc=',ntmax,irc
         endif
      endif
      if (irc /= 0) then
         call PPABORT()
         stop
      endif
!
! move particles into appropriate spatial regions with MPI:
! updates rbufr, rbufl, mcll, mclr
      call mpmove3(sbufr,sbufl,rbufr,rbufl,ncll,nclr,mcll,mclr,mcls,tmov&
     &,kstrt,nvpy,nvpz,myp1,mzp1,irc)
!
! second part of particle reorder on x, y, and z cell
! with mx, my, mz tiles: updates ppart, kpic
      call mporder3b(ppart,ppbuff,rbufl,rbufr,kpic,ncl,ihole,mcll,mclr, &
     &mcls,tsort,myp1,irc)
      if (irc /= 0) then
         write (*,*) kstrt,'mporder3b error: nppmx, irc=',nppmx,irc
         call PPABORT()
         stop
      endif
      end subroutine
!
!-----------------------------------------------------------------------
      subroutine wmpfft3r(f,h,noff,nyzp,isign,mixup,sct,tfft,tfmov,indx,&
     &indy,indz,kstrt,nvpy,nvpz,kxyp,kyp,kyzp,kzp,ny,nz,mter,ierr)
! performs 3d real/complex FFT for scalar data
! data in real space has a non-uniform partition,
! data in fourier space has a uniform partition
      implicit none
      integer, intent(in) :: isign, indx, indy, indz, kstrt, nvpy, nvpz
      integer, intent(in) :: kxyp, kyp, kyzp, kzp, ny, nz
      integer, intent(inout) :: ierr
      real, intent(inout) :: tfmov
      real, dimension(:,:,:), intent(inout) :: f
      complex, dimension(:,:,:), intent(inout) :: h
      integer, dimension(:), intent(in) :: noff, nyzp
      integer, dimension(:), intent(in) :: mixup
      complex, dimension(:), intent(in) :: sct
      real, dimension(2), intent(inout) :: tfft
      integer, dimension(2), intent(inout) :: mter
! inverse fourier transform: from real to complex
      if (isign < 0) then
! moves scalar grids from non-uniform to uniform partition
         call mpfmove3(f,noff,nyzp,isign,tfmov,kyp,kzp,ny,nz,kstrt,nvpy,&
     &nvpz,mter,ierr)
! wrapper function for scalar 3d real/complex FFT
         call mpfft3r(f,h,isign,mixup,sct,tfft,indx,indy,indz,kstrt,nvpy&
     &,nvpz,kxyp,kyp,kyzp,kzp)
! forward fourier transform: from complex to real
      else if (isign > 0) then
! wrapper function for scalar 3d real/complex FFT
         call mpfft3r(f,h,isign,mixup,sct,tfft,indx,indy,indz,kstrt,nvpy&
     &,nvpz,kxyp,kyp,kyzp,kzp)
! moves scalar grids from uniform to non-uniform partition
         call mpfmove3(f,noff,nyzp,isign,tfmov,kyp,kzp,ny,nz,kstrt,nvpy,&
     &nvpz,mter,ierr)
      endif
      end subroutine
!
!-----------------------------------------------------------------------
      subroutine wmpfft3rn(f,h,noff,nyzp,isign,mixup,sct,tfft,tfmov,indx&
     &,indy,indz,kstrt,nvpy,nvpz,kxyp,kyp,kyzp,kzp,ny,nz,mter,ierr)
! performs 3d real/complex FFT for n component vector data
! data in real space has a non-uniform partition,
! data in fourier space has a uniform partition
      implicit none
      integer, intent(in) :: isign, indx, indy, indz, kstrt, nvpy, nvpz
      integer, intent(in) :: kxyp, kyp, kyzp, kzp, ny, nz
      integer, intent(inout) :: ierr
      real, intent(inout) :: tfmov
      real, dimension(:,:,:,:), intent(inout) :: f
      complex, dimension(:,:,:,:), intent(inout) :: h
      integer, dimension(:), intent(in) :: noff, nyzp
      integer, dimension(:), intent(in) :: mixup
      complex, dimension(:), intent(in) :: sct
      real, dimension(2), intent(inout) :: tfft
      integer, dimension(2), intent(inout) :: mter
! inverse fourier transform
      if (isign < 0) then
! moves vector grids from non-uniform to uniform partition
         call mpfnmove3(f,noff,nyzp,isign,tfmov,kyp,kzp,ny,nz,kstrt,nvpy&
     &,nvpz,mter,ierr)
! wrapper function for n component vector 3d real/complex FFT
         call mpfft3rn(f,h,isign,mixup,sct,tfft,indx,indy,indz,kstrt,   &
     &nvpy,nvpz,kxyp,kyp,kyzp,kzp)
! forward fourier transform
      else if (isign > 0) then
! wrapper function for n component vector 3d real/complex FFT
         call mpfft3rn(f,h,isign,mixup,sct,tfft,indx,indy,indz,kstrt,   &
     &nvpy,nvpz,kxyp,kyp,kyzp,kzp)
! moves vector grids from uniform to non-uniform partition
         call mpfnmove3(f,noff,nyzp,isign,tfmov,kyp,kzp,ny,nz,kstrt,nvpy&
     &,nvpz,mter,ierr)
      endif
      end subroutine
!
!-----------------------------------------------------------------------
      subroutine wmpcguard3(f,nyzp,tguard,nx,kstrt,nvpy,nvpz)
! copy scalar guard cells to local and remote partitions
      implicit none
      integer, intent(in) :: nx, kstrt, nvpy, nvpz
      real, intent(inout) :: tguard
      real, dimension(:,:,:), intent(inout) :: f
      integer, dimension(:), intent(in) :: nyzp
! copies data to guard cells in non-uniform partitions
      call mpcguard3(f,nyzp,tguard,kstrt,nvpy,nvpz)
! replicates local periodic scalar field
      call mpdguard3x(f,nyzp,tguard,nx)
      end subroutine
!
!-----------------------------------------------------------------------
      subroutine wmpncguard3(f,nyzp,tguard,nx,kstrt,nvpy,nvpz)
! copy vector guard cells to local and remote partitions
      implicit none
      integer, intent(in) :: nx, kstrt, nvpy, nvpz
      real, intent(inout) :: tguard
      real, dimension(:,:,:,:), intent(inout) :: f
      integer, dimension(:), intent(in) :: nyzp
! copies data to guard cells in non-uniform partitions
      call mpncguard3(f,nyzp,tguard,kstrt,nvpy,nvpz)
! replicates local periodic vector field
      call mpcguard3x(f,nyzp,tguard,nx)
      end subroutine
!
!-----------------------------------------------------------------------
      subroutine wmpaguard3(f,nyzp,tguard,nx,kstrt,nvpy,nvpz)
! add scalar guard cells from local and remote partitions
      implicit none
      integer, intent(in) :: nx, kstrt, nvpy, nvpz
      real, intent(inout) :: tguard
      real, dimension(:,:,:), intent(inout) :: f
      integer, dimension(:), intent(in) :: nyzp
! accumulates local periodic scalar field
      call mpaguard3x(f,nyzp,tguard,nx)
! adds scalar data from guard cells in non-uniform partitions
      call mpnaguard3(f,nyzp,tguard,nx,kstrt,nvpy,nvpz)
      end subroutine
!
!-----------------------------------------------------------------------
      subroutine wmpnacguard3(f,nyzp,tguard,nx,kstrt,nvpy,nvpz)
! add vector guard cells from local and remote partitions
      implicit none
      integer, intent(in) :: nx, kstrt, nvpy, nvpz
      real, intent(inout) :: tguard
      real, dimension(:,:,:,:), intent(inout) :: f
      integer, dimension(:), intent(in) :: nyzp
! accumulates local periodic vector field
      call mpacguard3x(f,nyzp,tguard,nx)
! adds vector data from guard cells in non-uniform partitions
      call mpnacguard3(f,nyzp,tguard,nx,kstrt,nvpy,nvpz)
      end subroutine
!
      end module
